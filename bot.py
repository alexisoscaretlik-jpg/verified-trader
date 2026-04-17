"""
Trading Alert Agent
===================
Gmail (IMAP) → Claude API (parse) → IBKR (execute)

Single worker process. Deploy on Railway as: python bot.py
"""

import imaplib
import email
import json
import os
import time
import csv
import hashlib
import logging
import re
from datetime import datetime, timezone
from email.header import decode_header
from anthropic import Anthropic

# ── Config ────────────────────────────────────────────────────────────────────

EMAIL_USERNAME = os.environ["EMAIL_USERNAME"]
EMAIL_PASSWORD = os.environ["EMAIL_PASSWORD"]
ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
ALERT_SENDER = os.environ.get("ALERT_SENDER", "verifiedinvesting.com")

IB_HOST = os.environ.get("IB_HOST", "127.0.0.1")
IB_PORT = int(os.environ.get("IB_PORT", "4002"))
IB_CLIENT_ID = int(os.environ.get("IB_CLIENT_ID", "1"))
IB_ACCOUNT = os.environ.get("IB_ACCOUNT", "")

KILL_SWITCH = os.environ.get("KILL_SWITCH", "false").lower() == "true"
PAPER_MODE = os.environ.get("PAPER_MODE", "true").lower() == "true"
MAX_SHARES = int(os.environ.get("MAX_SHARES_PER_TRADE", "500"))
MAX_PRICE_DEV_PCT = float(os.environ.get("MAX_PRICE_DEVIATION_PCT", "5"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))

PROCESSED_IDS_FILE = "processed_ids.json"
TRADES_LOG = "trades.csv"
BOT_LOG = "bot.log"

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(BOT_LOG),
    ],
)
log = logging.getLogger("bot")

# ── Claude Parser ─────────────────────────────────────────────────────────────

claude = Anthropic(api_key=ANTHROPIC_API_KEY)

PARSE_SYSTEM = """You are a trading alert parser for Verified Investing (Gareth Soloway's "The Swing Trader").

Return ONLY valid JSON. No markdown, no backticks, no explanation.

Schema:
{
  "ticker": "string — e.g. STX, AAPL, TSLA",
  "action": "OPEN_LONG | OPEN_SHORT | ADD_LONG | ADD_SHORT | REDUCE_LONG | REDUCE_SHORT | CLOSE_LONG | CLOSE_SHORT",
  "side": "Long | Short",
  "shares": integer,
  "price": float,
  "activity_pnl": float or null,
  "notes": "string or null",
  "ibkr_action": "BUY | SELL",
  "order_type": "LMT",
  "confidence": "high | medium | low"
}

Rules:
- "NEW LONG" / "OPEN LONG" / "BUY" → OPEN_LONG, ibkr_action=BUY
- "NEW SHORT" / "OPEN SHORT" / "SHORT" → OPEN_SHORT, ibkr_action=SELL
- "ADD" on Long → ADD_LONG, ibkr_action=BUY
- "ADD" on Short → ADD_SHORT, ibkr_action=SELL
- "REDUCE" on Long / "TRIM" → REDUCE_LONG, ibkr_action=SELL
- "REDUCE (COVER)" on Short → REDUCE_SHORT, ibkr_action=BUY
- "CLOSE" on Long → CLOSE_LONG, ibkr_action=SELL
- "CLOSE (COVER)" on Short → CLOSE_SHORT, ibkr_action=BUY

Key: "REDUCE (COVER)" + Side: Short = buy-to-cover → ibkr_action=BUY

Set confidence "low" if fields are missing or ambiguous."""


def parse_alert(subject, body):
    try:
        msg = claude.messages.create(
            model="claude-haiku-4-5-20241022",
            max_tokens=400,
            system=PARSE_SYSTEM,
            messages=[{"role": "user", "content": f"Subject: {subject}\n\nBody:\n{body}"}],
        )
        raw = msg.content[0].text.strip()
        log.info(f"Claude response: {raw}")
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[1].rsplit("```", 1)[0]
        parsed = json.loads(raw)
        parsed["_raw_response"] = raw
        return parsed
    except json.JSONDecodeError as e:
        log.error(f"JSON parse failed: {e}")
        return {"confidence": "low", "error": f"JSON parse error: {e}", "_raw_response": raw}
    except Exception as e:
        log.error(f"Claude API error: {e}")
        return {"confidence": "low", "error": str(e), "_raw_response": ""}


# ── IBKR Broker ───────────────────────────────────────────────────────────────

ib = None


def connect_ibkr():
    global ib
    try:
        from ib_insync import IB
        if ib and ib.isConnected():
            return True
        ib = IB()
        ib.connect(host=IB_HOST, port=IB_PORT, clientId=IB_CLIENT_ID, timeout=15)
        log.info(f"IBKR connected: {IB_HOST}:{IB_PORT}")
        return True
    except Exception as e:
        log.error(f"IBKR connection failed: {e}")
        return False


def get_position(ticker):
    if not ib or not ib.isConnected():
        return 0
    for pos in ib.positions():
        if pos.contract.symbol == ticker:
            return int(pos.position)
    return 0


def get_market_price(ticker):
    try:
        from ib_insync import Stock
        contract = Stock(ticker, "SMART", "USD")
        ib.qualifyContracts(contract)
        data = ib.reqMktData(contract, "", False, False)
        ib.sleep(2)
        price = data.last if data.last > 0 else data.close
        ib.cancelMktData(contract)
        return price if price > 0 else None
    except Exception as e:
        log.warning(f"Market price fetch failed: {e}")
        return None


def submit_order(ticker, action, qty, limit_price):
    try:
        from ib_insync import Stock, LimitOrder
        contract = Stock(ticker, "SMART", "USD")
        ib.qualifyContracts(contract)
        order = LimitOrder(action, qty, limit_price)
        trade = ib.placeOrder(contract, order)
        ib.sleep(1)
        log.info(f"Order placed: {action} {qty} {ticker} @ ${limit_price} -> {trade.orderStatus.status}")
        return {"success": True, "order_id": trade.order.orderId, "status": trade.orderStatus.status}
    except Exception as e:
        log.error(f"Order failed: {e}")
        return {"success": False, "error": str(e)}


# ── Safety Checks ─────────────────────────────────────────────────────────────


def safety_check(parsed):
    if KILL_SWITCH:
        return "KILL SWITCH ON"
    if parsed.get("confidence") == "low":
        return f"Low confidence: {parsed.get('error', 'ambiguous parse')}"
    required = ["ticker", "shares", "price", "ibkr_action"]
    missing = [f for f in required if not parsed.get(f)]
    if missing:
        return f"Missing fields: {missing}"
    if parsed["shares"] > MAX_SHARES:
        return f"Shares {parsed['shares']} > max {MAX_SHARES}"
    if ib and ib.isConnected():
        market = get_market_price(parsed["ticker"])
        if market and market > 0:
            dev = abs(parsed["price"] - market) / market * 100
            if dev > MAX_PRICE_DEV_PCT:
                return f"Price ${parsed['price']} deviates {dev:.1f}% from market ${market}"
    action = parsed.get("action", "")
    if "REDUCE" in action or "CLOSE" in action:
        pos = get_position(parsed["ticker"])
        if action.endswith("_LONG") and pos <= 0:
            return f"Can't reduce/close long - position is {pos}"
        if action.endswith("_SHORT") and pos >= 0:
            return f"Can't reduce/close short - position is {pos}"
    return None


# ── Email Monitor ─────────────────────────────────────────────────────────────


def load_processed_ids():
    try:
        with open(PROCESSED_IDS_FILE) as f:
            return set(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return set()


def save_processed_ids(ids):
    with open(PROCESSED_IDS_FILE, "w") as f:
        json.dump(list(ids), f)


def decode_mime_header(raw):
    parts = decode_header(raw)
    decoded = []
    for data, charset in parts:
        if isinstance(data, bytes):
            decoded.append(data.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(data)
    return "".join(decoded)


def get_email_body(msg):
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            if ctype == "text/plain":
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or "utf-8"
                    return payload.decode(charset, errors="replace")
            elif ctype == "text/html":
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or "utf-8"
                    html = payload.decode(charset, errors="replace")
                    return re.sub(r"<[^>]+>", " ", html)
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or "utf-8"
            return payload.decode(charset, errors="replace")
    return ""


def log_trade(parsed, order_result, safety_msg):
    file_exists = os.path.exists(TRADES_LOG)
    with open(TRADES_LOG, "a", newline="") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow([
                "timestamp", "ticker", "action", "side", "shares", "price",
                "ibkr_action", "confidence", "safety_block", "order_status",
                "order_id", "notes",
            ])
        writer.writerow([
            datetime.now(timezone.utc).isoformat(),
            parsed.get("ticker", ""),
            parsed.get("action", ""),
            parsed.get("side", ""),
            parsed.get("shares", ""),
            parsed.get("price", ""),
            parsed.get("ibkr_action", ""),
            parsed.get("confidence", ""),
            safety_msg or "",
            order_result.get("status", order_result.get("error", "")) if order_result else "BLOCKED",
            order_result.get("order_id", "") if order_result else "",
            parsed.get("notes", ""),
        ])


def check_emails():
    processed = load_processed_ids()
    try:
        mail = imaplib.IMAP4_SSL("imap.gmail.com")
        mail.login(EMAIL_USERNAME, EMAIL_PASSWORD)
        mail.select("INBOX")
        _, data = mail.search(None, f'(FROM "{ALERT_SENDER}" UNSEEN)')
        email_ids = data[0].split()
        if not email_ids:
            mail.logout()
            return
        log.info(f"Found {len(email_ids)} new alert emails")
        for eid in email_ids:
            uid = eid.decode()
            if uid in processed:
                log.info(f"Skipping already processed: {uid}")
                continue
            _, msg_data = mail.fetch(eid, "(RFC822)")
            raw_email = msg_data[0][1]
            msg = email.message_from_bytes(raw_email)
            subject = decode_mime_header(msg.get("Subject", ""))
            sender = decode_mime_header(msg.get("From", ""))
            body = get_email_body(msg)
            log.info(f"Processing: [{subject}] from [{sender}]")
            parsed = parse_alert(subject, body)
            log.info(f"Parsed: {json.dumps({k:v for k,v in parsed.items() if k != '_raw_response'}, indent=2)}")
            block_reason = safety_check(parsed)
            if block_reason:
                log.warning(f"BLOCKED: {block_reason}")
                log_trade(parsed, None, block_reason)
                processed.add(uid)
                save_processed_ids(processed)
                continue
            if PAPER_MODE and not (ib and ib.isConnected()):
                log.info(f"PAPER MODE: Would {parsed['ibkr_action']} {parsed['shares']} {parsed['ticker']} @ ${parsed['price']}")
                order_result = {"status": "PAPER_SIMULATED", "order_id": "paper"}
            else:
                order_result = submit_order(parsed["ticker"], parsed["ibkr_action"], parsed["shares"], parsed["price"])
            log_trade(parsed, order_result, None)
            log.info(f"Trade logged: {parsed['ticker']} -> {order_result}")
            processed.add(uid)
            save_processed_ids(processed)
        mail.logout()
    except imaplib.IMAP4.error as e:
        log.error(f"IMAP error: {e}")
    except Exception as e:
        log.error(f"Email check error: {e}", exc_info=True)


# ── Main Loop ─────────────────────────────────────────────────────────────────


def main():
    log.info("=" * 60)
    log.info("TRADING ALERT AGENT STARTING")
    log.info(f"  Email:    {EMAIL_USERNAME}")
    log.info(f"  Sender:   {ALERT_SENDER}")
    log.info(f"  IBKR:     {IB_HOST}:{IB_PORT}")
    log.info(f"  Paper:    {PAPER_MODE}")
    log.info(f"  Kill:     {KILL_SWITCH}")
    log.info(f"  Poll:     every {POLL_INTERVAL}s")
    log.info("=" * 60)
    if not PAPER_MODE:
        if connect_ibkr():
            log.info("IBKR connected - live trading enabled")
        else:
            log.warning("IBKR not connected - will retry on each trade")
    else:
        log.info("Paper mode - IBKR connection optional")
        connect_ibkr()
    while True:
        try:
            check_emails()
        except Exception as e:
            log.error(f"Unhandled error in main loop: {e}", exc_info=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
