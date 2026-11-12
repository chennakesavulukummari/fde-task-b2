# FDE Task Tracker

The UI, API, and MySQL database run together with Docker Compose. Compose builds the UI and API images from this repository and pulls the official MySQL image.

## Run locally or on EC2

1. Install Docker Engine and the Docker Compose v2 plugin. On Ubuntu 24.04:

   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io docker-compose-v2 git openssl
   sudo systemctl enable --now docker
   ```

2. Clone this repository and enter its root directory:

   ```bash
   git clone <repository-url> fde-task-b2
   cd fde-task-b2
   ```

3. Create a private `.env` file with unique database passwords:

   ```bash
   DB_PASSWORD="$(openssl rand -hex 32)"
   DB_ROOT_PASSWORD="$(openssl rand -hex 32)"
   umask 077
   printf 'DB_PASSWORD=%s\nDB_ROOT_PASSWORD=%s\nHTTP_PORT=80\n' \
     "$DB_PASSWORD" "$DB_ROOT_PASSWORD" > .env
   unset DB_PASSWORD DB_ROOT_PASSWORD
   ```

4. Build the UI and API images, pull MySQL, and start all three services:

   ```bash
   sudo docker compose up --build -d
   ```

   MySQL uses the official `mysql:8.0` image, so Compose pulls it rather than building a local DB image. Database files persist in the `mysql_data` volume.

5. Check service status and the API health endpoint:

   ```bash
   sudo docker compose ps
   curl --fail http://localhost/api/health
   ```

   Open `http://localhost/` locally. On EC2, open `http://<EC2-PUBLIC-IP>/`.

## EC2 network access

Allow inbound TCP port 80 from the clients that need the app, and allow SSH (port 22) only from your IP. Do not expose ports 8000 or 3306; the API and database are reachable only within the Compose network.

## Useful commands

```bash
sudo docker compose build
sudo docker compose up -d
sudo docker compose up --build -d
sudo docker compose logs -f
sudo docker compose ps
sudo docker compose down
```

`docker compose build` builds the UI and API images; MySQL is pulled from the official `mysql:8.0` image when the stack starts. `docker compose up --build -d` builds the application images and starts the whole stack in one command. `docker compose down` preserves the database volume. `docker compose down --volumes` permanently deletes the persisted task data. Back up the volume before replacing or terminating an EC2 instance. Keep `.env` private and never commit it.
