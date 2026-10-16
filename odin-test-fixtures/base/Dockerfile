FROM python:3.12-slim

RUN useradd --create-home --uid 10001 agent
WORKDIR /app
COPY src/ ./src/
USER agent

EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)" || exit 1

CMD ["python", "src/agent.py"]
