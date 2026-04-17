import os
import imaplib
import email
import json
import time
import csv
import logging
from datetime import datetime
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
# Note: Railway internal service name (e.g., 'ib-gateway') or '127.0.0.1'
IB_HOST = os.environ.get("IB_HOST", "ib-gateway") 
IB_PORT = int(os.environ.get("IB_PORT", "4002")) 

PROCESSED_IDS_FILE = "processed_ids.json"
TRADES_LOG = "trades.csv"

# ── IBKR ENGINE ───────────────────────────────────────────────────────────────
ib = IB()

def connect_ibkr():
    if not ib.isConnected():
        try:
            log.info(f"Connecting to IBKR at {IB_HOST}:{IB_PORT}...")
            ib.connect(IB_HOST, IB_PORT, clientId=1, timeout=10)
        except Exception as e:
            log.error(f"IBKR Connection Error: {e}")
    return ib.isConnected()

def submit_order(ticker, action, quantity, price=None):
    if not connect_ibkr():
        return "FAILED_CONNECTION"
    
    try:
        # Ensure quantity is an integer
        qty = int(quantity)
        contract = Stock(ticker.upper(), 'SMART', 'USD')
        ib.qualifyContracts(contract)
        
        if price and float(price) > 0:
            order = LimitOrder(action.upper(), qty, float(price))
        else:
            order = MarketOrder(action.upper(), qty)
            
        trade = ib.placeOrder(contract, order)
        log.info(f"Order Sent: {action} {qty} {ticker}")
        return "SUBMITTED"
    except Exception as e:
        log.error(f"Order Error: {e}")
        return "ERROR"

# ── CLAUDE PARSER (FIXED FOR 2026) ───────────────────────────────────────────
claude = Anthropic(api_key=ANTHROPIC_API_KEY)

def parse_alert(subject, body):
    try:
        # UPDATED MODEL ID FOR APRIL 2026
        target_model = "claude-sonnet-4-6" 
        
        prompt = f"Parse this trade alert into JSON. 'ibkr_action' must be 'BUY' or 'SELL'. Alert: {subject} {body}"
        
        msg = claude.messages.create(
            model=target_model,
            max_tokens=400,
            system="Return ONLY raw JSON with keys: ticker, action, shares, price, ibkr_action.",
            messages=[{"role": "user", "content": prompt}]
        )
        
        text = msg.content[0].text
        # Clean markdown if Claude adds it
        if "```json" in text:
            text = text.split("```json")[1].split("```")[0]
        return json.loads(text.strip())
    except Exception as e:
        log.error(f"Claude Error: {e}")
        return {"ticker": "ERROR"}

# ── CORE LOOP ─────────────────────────────────────────────────────────────────
def check_emails():
    try:
        mail = imaplib.IMAP4_SSL("imap.gmail.com")
        mail.login(EMAIL_USERNAME, EMAIL_PASSWORD)
        mail.select("INBOX")
        
        _, data = mail.search(None, f'(FROM "{ALERT_SENDER}" UNSEEN)')
        for eid in data[0].split():
            _, msg_data = mail.fetch(eid, "(RFC822)")
            msg = email.message_from_bytes(msg_data[0][1])
            subject = str(msg.get("Subject", ""))
            
            # Simple body extraction
            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    if part.get_content_type() == "text/plain":
                        body = part.get_payload(decode=True).decode()
            else:
                body = msg.get_payload(decode=True).decode()

            log.info(f"Processing Alert: {subject}")
            parsed = parse_alert(subject, body)
            
            if parsed.get("ticker") != "ERROR":
                # Execute trade on IBKR (Paper or Live based on Port/Host)
                result = submit_order(
                    parsed['ticker'], 
                    parsed['ibkr_action'], 
                    parsed.get('shares', 10), 
                    parsed.get('price')
                )
                log.info(f"Trade Result: {result}")
        
        mail.logout()
    except Exception as e:
        log.error(f"Email Loop Error: {e}")

if __name__ == "__main__":
    log.info("=== BOT STARTING (APRIL 2026 VERSION) ===")
    while True:
        check_emails()
        time.sleep(POLL_INTERVAL)
