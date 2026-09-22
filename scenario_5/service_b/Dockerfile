FROM python:3.11.9-slim-bookworm@sha256:8fb099199b9f2d70342674bd9dbccd3ed03a258f26bbd1d556822c6dfc60c317
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir --disable-pip-version-check -r requirements.txt
COPY app.py .
CMD ["gunicorn", "--workers=4", "--threads=4", "--worker-class=gthread", "--timeout=10", "--graceful-timeout=10", "--keep-alive=5", "--bind=0.0.0.0:5000", "app:app"]
