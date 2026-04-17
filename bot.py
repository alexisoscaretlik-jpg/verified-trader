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

# ── LOGGING SETUP ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()]
)
log = logging.getLogger("bot")

print("REALLY STARTING NOW - INITIALIZING BOT")

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
try:
    EMAIL_USERNAME = os.environ["EMAIL_USERNAME"]
    EMAIL_PASSWORD = os.environ["EMAIL_PASSWORD"]
    ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
except KeyError as e:
    print(f"CRITICAL ERROR: Missing environment variable: {e}")
    raise

# Use the full email address for the sender filter
ALERT_SENDER = os.environ.get("ALERT_SENDER", "parisbrugemons@gmail.com")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))
PAPER_MODE = os.environ.get("PAPER_MODE", "true").lower() == "true"
KILL_SWITCH = os.environ.get("KILL_SWITCH", "false").lower() == "true"
MAX_SHARES = int(os.environ.get("MAX_SHARES_PER_TRADE", "500"))

IB_HOST = os.environ.get("IB_HOST", "127.0.0.1")
IB_PORT = int(os.environ.get("IB_PORT", "4002"))

PROCESSED_IDS_FILE = "processed_ids.json"
TRADES_LOG = "trades.csv"

# ── CLAUDE PARSER (2026 MODEL) ────────────────────────────────────────────────
claude = Anthropic(api_key=ANTHROPIC_API_KEY)

def parse_alert(subject, body):
    try:
        prompt = f"Parse this trading alert into JSON with keys: ticker, action, side, shares, price, ibkr_action. Alert: {subject} {body}"
        msg = claude.messages.create(
            model="claude-3-5-sonnet-latest", 
            max_tokens=400,
            system="Return ONLY JSON.",
            messages=[{"role": "user", "content": prompt}]
        )
        text = msg.content[0].text
        if "```json" in text:
            text = text.split("```json")[1].split("```")[0]
        return json.loads(text)
    except Exception as e:
        log.error(f"Claude Error: {e}")
        return {"ticker": "ERROR"}

# ── HELPERS ───────────────────────────────────────────────────────────────────
def load_processed_ids():
    if os.path.exists(PROCESSED_IDS_FILE):
        try:
            with open(PROCESSED_IDS_FILE, 'r') as f:
                return set(json.load(f))
        except: return set()
    return set()

def save_processed_ids(ids):
    with open(PROCESSED_IDS_FILE, 'w') as f:
        json.dump(list(ids), f)

def decode_mime_header(raw):
    parts = decode_header(raw or "")
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
            if part.get_content_type() == "text/plain":
                return part.get_payload(decode=True).decode(errors="replace")
    return msg.get_payload(decode=True).decode(errors="replace")

def log_trade(parsed, result, safety):
    file_exists = os.path.exists(TRADES_LOG)
    with open(TRADES_LOG, "a", newline="") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(["ts", "ticker", "action", "shares", "price", "status"])
        writer.writerow([datetime.now().isoformat(), parsed.get('ticker'), parsed.get('action'), 
                         parsed.get('shares'), parsed.get('price'), safety or result])

# ── BROKER STUBS ──────────────────────────────────────────────────────────────
def safety_check(parsed):
    if KILL_SWITCH: return "KILL SWITCH ACTIVE"
    if not parsed.get("ticker") or parsed["ticker"] == "ERROR": return "INVALID DATA"
    if int(parsed.get("shares", 0)) > MAX_SHARES: return "EXCEEDS MAX SHARES"
    return None

def submit_order(t, a, q, p):
    log.info(f"LIVE ORDER: {a} {q} {t} @ {p}")
    return {"status": "SUBMITTED", "order_id": "123"}

# ── CORE LOGIC ────────────────────────────────────────────────────────────────
def check_emails():
    processed = load_processed_ids()
    try:
        log.info("Connecting to Gmail...")
        mail = imaplib.IMAP4_SSL("imap.gmail.com")
        mail.login(EMAIL_USERNAME, EMAIL_PASSWORD)
        mail.select("INBOX")
        
        log.info(f"Searching: FROM {ALERT_SENDER} (UNSEEN)")
        # --- FIXED LINE BELOW ---
        _, data = mail.search(None, f'(FROM "{ALERT_SENDER}" UNSEEN)')
        email_ids = data[0].split()
        
        if not email_ids:
            log.info("No new alerts found.")
            mail.logout()
            return

        for eid in email_ids:
            uid = eid.decode()
            if uid in processed: continue

            _, msg_data = mail.fetch(eid, "(RFC822)")
            msg = email.message_from_bytes(msg_data[0][1])
            subject = decode_mime_header(msg.get("Subject", ""))
            body = get_email_body(msg)
            
            log.info(f"Processing: {subject}")
            parsed = parse_alert(subject, body)
            
            block
