# category-suggester — a one-shot job, run by cron through `docker compose run`.
FROM python:3.13.15-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY suggester/ suggester/

# /data holds the SQLite memory of rejected suggestions. Creating it here, owned
# by the runtime user, is what makes a fresh named volume writable by that user.
RUN useradd --system --uid 10001 --home /app suggester \
    && mkdir /data && chown suggester /data
USER suggester
VOLUME /data

ENTRYPOINT ["python", "-m", "suggester"]
CMD ["suggest"]
