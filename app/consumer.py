"""Lead consumer (runs on app01 as a systemd service).

Reads leads from the 'leads' queue (manual ack), saves each lead to MariaDB
and sends an email via SMTP (Mailpit in the lab).

Retry policy - 3 attempts in total:
  attempt 1 fails -> back to the 'leads' queue immediately
  attempt 2 fails -> 'leads.retry', waits 24 hours, then RabbitMQ
                     dead-letters it back to 'leads'
  attempt 3 fails -> 'leads.failed' and stays there for manual checking
                     (nothing consumes that queue, the message is never deleted)

Message headers we add on a failure:
  failed_attempts - how many attempts failed so far
  db_saved        - True if the DB insert already worked (so a retry
                    only sends the email and does not insert twice)
"""
import json
import logging
import os
import smtplib
from email.message import EmailMessage

import pika
import pymysql

# Settings come from /etc/leadapp.env (loaded by systemd)
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["APP_DB_PASS"]
MQ_HOST = os.environ["MQ_HOST"]
MQ_USER = os.environ["MQ_USER"]
MQ_PASS = os.environ["APP_MQ_PASS"]
SMTP_HOST = os.environ["SMTP_HOST"]
SMTP_PORT = int(os.environ["SMTP_PORT"])
MAIL_FROM = os.environ["LEAD_NOTIFY_FROM"]
MAIL_TO = os.environ["LEAD_NOTIFY_TO"]

MAIN_QUEUE = "leads"
RETRY_QUEUE = "leads.retry"
FAILED_QUEUE = "leads.failed"
RETRY_DELAY_MS = 24 * 60 * 60 * 1000  # 24 hours in milliseconds
MAX_ATTEMPTS = 3

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("consumer")


def save_to_db(lead):
    """Insert the lead into leads.contact_form."""
    connection = pymysql.connect(
        host=DB_HOST, user=DB_USER, password=DB_PASS, database=DB_NAME, connect_timeout=5
    )
    try:
        with connection.cursor() as cursor:
            # %s placeholders: PyMySQL escapes the values (no SQL injection)
            cursor.execute(
                "INSERT INTO contact_form (name, company_name, email, phone) VALUES (%s, %s, %s, %s)",
                (lead["name"], lead["company_name"], lead["email"], lead["phone"]),
            )
        connection.commit()
    finally:
        connection.close()


def send_email(lead):
    """Send an email with the lead details."""
    message = EmailMessage()
    message["Subject"] = f"New lead: {lead['name']} ({lead['company_name']})"
    message["From"] = MAIL_FROM
    message["To"] = MAIL_TO
    message.set_content(
        "New lead from the contact form:\n\n"
        f"Name:    {lead['name']}\n"
        f"Company: {lead['company_name']}\n"
        f"Email:   {lead['email']}\n"
        f"Phone:   {lead['phone']}\n"
    )
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as smtp:
        smtp.send_message(message)


def handle_message(channel, method, properties, body):
    """Called by pika for every message in the 'leads' queue."""
    headers = properties.headers or {}
    attempt = headers.get("failed_attempts", 0) + 1  # 1, 2 or 3
    db_saved = headers.get("db_saved", False)

    try:
        lead = json.loads(body)
        if not db_saved:
            save_to_db(lead)
            db_saved = True
        send_email(lead)
        log.info("Lead saved and email sent (attempt %s)", attempt)
    except Exception:
        log.exception("Attempt %s failed", attempt)

        # Choose where the message goes next
        if attempt == 1:
            next_queue = MAIN_QUEUE  # retry immediately
        elif attempt < MAX_ATTEMPTS:
            next_queue = RETRY_QUEUE  # retry after 24 hours
        else:
            next_queue = FAILED_QUEUE  # give up, keep it for manual checking

        # Publish a copy with the updated headers
        channel.basic_publish(
            exchange="",
            routing_key=next_queue,
            body=body,
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=2,  # persistent
                headers={"failed_attempts": attempt, "db_saved": db_saved},
            ),
        )
        log.warning("Message moved to the '%s' queue", next_queue)

    # Manual ack: only now RabbitMQ deletes the original message.
    # If the consumer crashes before this line, RabbitMQ delivers the message again.
    channel.basic_ack(delivery_tag=method.delivery_tag)


def main():
    credentials = pika.PlainCredentials(MQ_USER, MQ_PASS)
    parameters = pika.ConnectionParameters(host=MQ_HOST, credentials=credentials)
    connection = pika.BlockingConnection(parameters)
    channel = connection.channel()

    # All queues are durable (they survive a RabbitMQ restart)
    channel.queue_declare(queue=MAIN_QUEUE, durable=True)
    # Retry queue: nobody consumes it. After the TTL (24h) RabbitMQ
    # dead-letters the message to the default exchange ("") with routing
    # key 'leads', so it goes back to the main queue.
    channel.queue_declare(
        queue=RETRY_QUEUE,
        durable=True,
        arguments={
            "x-message-ttl": RETRY_DELAY_MS,
            "x-dead-letter-exchange": "",
            "x-dead-letter-routing-key": MAIN_QUEUE,
        },
    )
    # Failed queue: no TTL and no consumer, so messages stay until a human checks them
    channel.queue_declare(queue=FAILED_QUEUE, durable=True)

    # Publisher confirms: re-published messages are safe before we ack the original
    channel.confirm_delivery()
    # Take one message at a time
    channel.basic_qos(prefetch_count=1)
    # auto_ack is False by default = manual ack in handle_message()
    channel.basic_consume(queue=MAIN_QUEUE, on_message_callback=handle_message)

    log.info("Waiting for leads...")
    channel.start_consuming()


if __name__ == "__main__":
    main()
