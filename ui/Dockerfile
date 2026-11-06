FROM nginxinc/nginx-unprivileged:1.29-alpine

LABEL com.azure.containerizationassist.createdby="containerization-assist"

COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css app.js /usr/share/nginx/html/

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --spider -q http://127.0.0.1:8080/ || exit 1
