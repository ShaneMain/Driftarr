FROM python:3.12-alpine

WORKDIR /app
COPY sync/ /app/configs/sync/

ENTRYPOINT ["python", "-m", "configs.sync.sync"]
