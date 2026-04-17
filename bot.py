import os
import imaplib
import email
import json
import time
import csv
import logging
from datetime import datetime
from email.header import decode_header
from anthropic import Anthropic
from ib_insync import IB, Stock, MarketOrder, LimitOrder

# ── LOGGING SETUP ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()]
)
log = logging.getLogger("bot")

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
try:
    EMAIL_USERNAME = os.environ["EMAIL_USERNAME"]
    EMAIL_PASSWORD = os.environ["EMAIL_PASSWORD"]
    ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
except KeyError as e:
    log.error(f"CRITICAL ERROR: Missing environment variable: {e}")
    raise

ALERT_SENDER = os.environ.get("ALERT_SENDER", "parisbrugemons@gmail.com")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))
PAPER_MODE = os.environ.get("PAPER_MODE", "true").lower() == "true"

IB_HOST = os.environ.get("IB_HOST", "127.0.0.1")
IB_PORT = int(os.environ.get("IB_PORT", "4002"))

PROCESSED_IDS_FILE = "processed_ids.json"
TRADES_LOG = "trades.csv"

# ── IBKR ENGINE ───────────────────────────────────────────────────────────────
ib = IB()

def connect_ibkr():
    if not ib.isConnected():
        try:
            log.info(f"Connecting to IBKR at {IB_HOST}:{IB_PORT}...")
            ib.connect(IB_HOST, IB_PORT, clientId=1)
        except Exception as e:
            log.error(f"IBKR Connection Error: {e}")
    return ib.isConnected()

def submit_order(ticker, action, quantity, price=None):
    if not connect_ibkr():
        return "FAILED_CONNECTION"
    
    try:
        contract = Stock(ticker, 'SMART', 'USD')
        ib.qualifyContracts(contract)
        
        if price and float(price) > 0:
            order = LimitOrder(action.upper(), quantity, price)
        else:
            order = MarketOrder(action.upper(), quantity)
            
        trade = ib.placeOrder(contract, order)
        ib.sleep(1) # Wait for confirmation
        return trade.orderStatus.status
    except Exception as e:
        log.error(f"Order Error: {e}")
        return "ERROR"

# ── CLAUDE 4 PARSER (FIXES 404) ───────────────────────────────────────────────
claude = Anthropic(api_key=ANTHROPIC_API_KEY)

def parse_alert(subject, body):
    try:
        prompt = f"Parse this alert into JSON: ticker, action, shares, price, ibkr_action. Alert: {subject} {body}"
        msg = claude.messages.create(
            model="claude-4-sonnet-latest", # April 2026 Stable Version
            max_tokens=400,
            system="Return ONLY JSON.",
            messages=[{"role": "user", "content": prompt}]
        )
        text = msg.content[0].text
        if "```json" in text:
            text = text.split("```json")[1].split("```")[0]
        return json.loads(text.strip())
    except Exception as e:
        log.error(f"Claude Error: {e}")
        return {"ticker": "ERROR"}

# ── HELPERS ───────────────────────────────────────────────────────────────────
def load_processed_ids():
    if os.path.exists(PROCESSED_IDS_FILE):
        try:
            with open(PROCESSED_IDS_FILE, 'r') as f: return set(json.load(f))
        except: return set()
    return set()

def save_processed_ids(ids):
    with open(PROCESSED_IDS_FILE, 'w') as f: json.dump(list(ids), f)

def get_email_body(msg):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                return part.get_payload(decode=True).decode(errors="replace")
    return msg.get_payload(decode=True).decode(errors="replace")

def log_trade(parsed, result):
    file_exists = os.path.exists(TRADES_LOG)
    with open(TRADES_LOG, "a", newline="") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(["ts", "ticker", "action", "shares", "status"])
        writer.writerow([datetime.now().isoformat(), parsed.get('ticker'), 
                         parsed.get('action'), parsed.get('shares'), result])

# ── CORE LOOP ─────────────────────────────────────────────────────────────────
def check_emails():
    processed = load_processed_ids()
    try:
        mail = imaplib.IMAP4_SSL("imap.gmail.com")
        mail.login(EMAIL_USERNAME, EMAIL_PASSWORD)
        mail.select("INBOX")
        
        _, data = mail.search(None, f'(FROM "{ALERT_SENDER}" UNSEEN)')
        for eid in data[0].split():
            uid = eid.decode()
            if uid in processed: continue

            _, msg_data = mail.fetch(eid, "(RFC822)")
            msg = email.message_from_bytes(msg_data[0][1])
            subject = str(msg.get("Subject", ""))
            body = get_email_body(msg)
            
            log.info(f"Signal Found: {subject}")
            parsed = parse_alert(subject, body)
            
            if parsed.get("ticker") != "ERROR":
                if PAPER_MODE:
                    log.info(f"PAPER SUCCESS: {parsed['ticker']}")
                    result = "PAPER_DONE"
                else:
                    result = submit_order(parsed['ticker'], parsed['ibkr_action'], 
                                          parsed['shares'], parsed.get('price'))
                log_trade(parsed, result)

            processed.add(uid)
            save_processed_ids(processed)
        mail.logout()
    except Exception as e:
        log.error(f"Loop Error: {e}")

def main():
    log.info("=" * 30)
    log.info(f"AGENT LIVE | MODE: {'PAPER' if PAPER_MODE else 'LIVE'}")
    log.info("=" * 30)
    while True:
        check_emails()
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
