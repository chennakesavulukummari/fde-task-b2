server {
    listen 80 default_server;
    server_name _;

    root /var/www/fde-task-app;
    index index.html;

    # Serve the frontend UI
    location / {
        try_files $uri $uri/ =404;
    }

    # Forward API requests to FastAPI on the API instance (private IP)
    location /api/ {
        proxy_pass http://__API_HOST__:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Swagger UI for interactive API testing
    location ~ ^/(docs|openapi\.json)$ {
        proxy_pass http://__API_HOST__:8000;
        proxy_set_header Host $host;
    }
}
