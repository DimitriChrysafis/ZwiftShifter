import os

import mysql.connector
from elasticsearch import Elasticsearch
from pymongo import MongoClient

MONGO_URI = os.environ.get("MONGO_URI", "mongodb://zwift:zwift@localhost:27018")
MYSQL_DSN = {
    "host": os.environ.get("MYSQL_HOST", "localhost"),
    "port": int(os.environ.get("MYSQL_PORT", "3307")),
    "user": os.environ.get("MYSQL_USER", "zwift"),
    "password": os.environ.get("MYSQL_PASSWORD", "zwift"),
    "database": os.environ.get("MYSQL_DB", "zwift"),
}
ES_URL = os.environ.get("ES_URL", "http://localhost:9299")


def mongo_db():
    return MongoClient(MONGO_URI).zwift


def mysql_conn():
    return mysql.connector.connect(**MYSQL_DSN)


def es():
    return Elasticsearch(ES_URL)
