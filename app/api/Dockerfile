# Minimal container for the ReelHouse API. Python slim base + gunicorn
# serving Flask. ~80 MB total image size.

FROM python:3.12-slim

# Avoid writing .pyc and buffer stdout — both nice in containers.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install deps first for build-cache friendliness.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

# ACA env var PORT defaults to 8080 (set by Terraform aca.tf).
EXPOSE 8080

# Gunicorn for production-ish concurrency. One worker is enough for
# lab demo; threading covers blocking SDK calls (KV, Blob, PG).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", \
     "--workers", "1", \
     "--threads", "8", \
     "--timeout", "120", \
     "main:app"]
