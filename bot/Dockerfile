FROM mcr.microsoft.com/azurelinux/base/python:3.12
WORKDIR /app
COPY requirements.txt .
RUN python3 -m pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV PORT=3978 PYTHONUNBUFFERED=1
EXPOSE 3978
USER 1000
CMD ["python3", "app.py"]
