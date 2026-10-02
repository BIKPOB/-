FROM python:3.12-slim
WORKDIR /app
RUN useradd --uid 10001 --create-home app && mkdir /data && chown app:app /data
COPY catalog_service.py /app/catalog_service.py
USER 10001:10001
EXPOSE 8080
CMD ["python", "catalog_service.py", "--host", "0.0.0.0", "--cache", "/data/catalog.json"]
