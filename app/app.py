"""Lead form web app (runs on app01 under gunicorn).

GET  /  -> show the form
POST /  -> validate, block duplicates with Memcached, publish to RabbitMQ
The web app never writes to the database - the consumer does that.
"""
import hashlib
import json
import logging
import os
import re

import pika
from flask import Flask, render_template_string, request
from pymemcache.client.base import Client

# Settings come from /etc/leadapp.env (loaded by systemd)
MQ_HOST = os.environ["MQ_HOST"]
MQ_USER = os.environ["MQ_USER"]
MQ_PASS = os.environ["APP_MQ_PASS"]
MC_HOST = os.environ["MC_HOST"]

QUEUE = "leads"
DUPLICATE_SECONDS = 600  # the same email is blocked for 10 minutes

# Max length of each field = size of its column in leads.contact_form
MAX_LENGTH = {"name": 50, "company_name": 200, "email": 100, "phone": 50}

# Simple email check: text@text.text with no spaces
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("leadapp")

app = Flask(__name__)

# One HTML template for all pages. render_template_string escapes the
# values, so user input cannot inject HTML into the page.
PAGE = """<!doctype html>
<html>
<head><meta charset="utf-8"><title>Contact us</title></head>
<body>
  <h1>Contact us</h1>
  {% if message %}<p><strong>{{ message }}</strong></p>{% endif %}
  {% if errors %}
  <ul>{% for error in errors %}<li>{{ error }}</li>{% endfor %}</ul>
  {% endif %}
  {% if show_form %}
  <form method="post">
    <p><label>Name<br><input name="name" maxlength="50" required value="{{ form.name }}"></label></p>
    <p><label>Company name<br><input name="company_name" maxlength="200" required value="{{ form.company_name }}"></label></p>
    <p><label>Email<br><input name="email" type="email" maxlength="100" required value="{{ form.email }}"></label></p>
    <p><label>Phone<br><input name="phone" maxlength="50" required value="{{ form.phone }}"></label></p>
    <p><button type="submit">Send</button></p>
  </form>
  {% endif %}
</body>
</html>"""


def validate(form):
    """Return a list of error messages (empty list = form is valid)."""
    errors = []
    for field, max_len in MAX_LENGTH.items():
        value = form[field]
        if not value:
            errors.append(f"{field} is required.")
        elif len(value) > max_len:
            errors.append(f"{field} must be at most {max_len} characters.")
        elif "\n" in value or "\r" in value:
            # New lines are not allowed - they could break the email headers
            errors.append(f"{field} must be a single line.")
    if form["email"] and not EMAIL_RE.match(form["email"]):
        errors.append("email is not a valid email address.")
    return errors


def memcache_key(email):
    # A hash of the email is always a valid Memcached key (no spaces, short)
    return "lead:" + hashlib.sha256(email.lower().encode()).hexdigest()


def first_submission(email):
    """Return True if this email was NOT submitted in the last 10 minutes.

    add() only stores the key if it does not exist yet, so two requests at
    the same moment cannot both pass the check.
    """
    try:
        client = Client((MC_HOST, 11211), connect_timeout=2, timeout=2)
        # noreply=False: wait for the answer, otherwise add() always returns True
        stored = client.add(memcache_key(email), b"1", expire=DUPLICATE_SECONDS, noreply=False)
        client.close()
        return stored
    except Exception:
        # Memcached is down: accept the lead - a duplicate is better than a lost lead
        log.exception("Memcached check failed, accepting the submission")
        return True


def forget_submission(email):
    """Remove the duplicate-check key, so the visitor can try again."""
    try:
        client = Client((MC_HOST, 11211), connect_timeout=2, timeout=2)
        client.delete(memcache_key(email))
        client.close()
    except Exception:
        log.exception("Could not remove the Memcached key")


def publish(lead):
    """Send the lead as a JSON message to the durable 'leads' queue."""
    credentials = pika.PlainCredentials(MQ_USER, MQ_PASS)
    parameters = pika.ConnectionParameters(host=MQ_HOST, credentials=credentials)
    connection = pika.BlockingConnection(parameters)
    try:
        channel = connection.channel()
        # durable=True: the queue survives a RabbitMQ restart
        channel.queue_declare(queue=QUEUE, durable=True)
        # Publisher confirms: basic_publish waits until RabbitMQ has the message
        channel.confirm_delivery()
        # exchange="" is the default exchange, it routes by queue name
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE,
            body=json.dumps(lead),
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=2,  # 2 = persistent: the message is written to disk
            ),
        )
    finally:
        connection.close()


@app.route("/", methods=["GET", "POST"])
def contact_form():
    if request.method == "GET":
        return render_template_string(PAGE, form={}, show_form=True)

    # Read only the fields we expect and remove spaces at the start and end
    form = {field: request.form.get(field, "").strip() for field in MAX_LENGTH}

    errors = validate(form)
    if errors:
        return render_template_string(PAGE, form=form, errors=errors, show_form=True), 400

    if not first_submission(form["email"]):
        return render_template_string(
            PAGE, message="Thanks, we already received your request a few minutes ago. We will contact you soon."
        )

    try:
        publish(form)
    except Exception:
        log.exception("Could not publish the lead to RabbitMQ")
        forget_submission(form["email"])
        return render_template_string(
            PAGE, form=form, show_form=True, message="Sorry, something went wrong. Please try again in a moment."
        ), 503

    log.info("Lead published to the '%s' queue", QUEUE)
    return render_template_string(PAGE, message="Thank you! We will contact you soon.")
