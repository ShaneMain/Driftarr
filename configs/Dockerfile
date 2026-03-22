FROM python:3.12.10-alpine3.22

WORKDIR /app
COPY sync/ /app/configs/sync/

ENTRYPOINT ["python", "-m", "configs.sync.sync"]
