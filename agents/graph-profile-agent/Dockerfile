FROM mcr.microsoft.com/azurelinux/base/python:3.12
WORKDIR /app
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py ./
EXPOSE 8088
USER 1000
CMD ["python", "main.py"]
