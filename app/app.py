#!/usr/bin/env python3

import os
import pymysql
import boto3
from datetime import datetime
from flask import Flask, render_template, request, redirect, jsonify

app = Flask(__name__)

dynamodb = boto3.resource('dynamodb', region_name=os.environ.get('AWS_REGION', 'eu-west-1'))
log_table = dynamodb.Table('week14-api-logs')

def get_db():
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        port=int(os.environ.get("DB_PORT", "3306")),
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5
    )

@app.route("/health")
def health():
    try:
        conn = get_db()
        conn.close()
        return "healthy", 200
    except Exception:
        return "unhealthy", 500

@app.route("/")
def index():
    conn = get_db()
    with conn.cursor() as cursor:
        cursor.execute("SELECT * FROM weather_log ORDER BY recorded_at DESC LIMIT 50")
        logs = cursor.fetchall()
    conn.close()
    return render_template("index.html", logs=logs)

@app.route("/log", methods=["POST"])
def add_log():
    city = request.form.get("city")
    temperature = request.form.get("temperature")
    conn = get_db()
    with conn.cursor() as cursor:
        cursor.execute(
            "INSERT INTO weather_log (city, temperature) VALUES (%s, %s)",
            (city, float(temperature))
        )
    conn.commit()
    conn.close()
    return redirect("/")

@app.route("/api/logs")
def api_logs():
    # Log the request to DynamoDB
    log_table.put_item(Item={
        'endpoint': '/api/logs',
        'timestamp': datetime.utcnow().isoformat(),
        'source': request.remote_addr
    })
    
    conn = get_db()
    with conn.cursor() as cursor:
        cursor.execute("SELECT * FROM weather_log ORDER BY recorded_at DESC")
        logs = cursor.fetchall()
    conn.close()
    # Convert datetime to string for JSON serialization
    for log in logs:
        if log.get("recorded_at"):
            log["recorded_at"] = str(log["recorded_at"])
    return jsonify(logs)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=False)
