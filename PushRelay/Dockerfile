FROM node:22-alpine

WORKDIR /app

# No dependencies: relay only uses Node.js built-ins
COPY --chown=node:node package.json server.js watcher.js apns.js ./

# Persistent notification state
RUN mkdir -p /app/data && chown node:node /app/data

ENV NODE_ENV=production \
    PUSH_BIND=0.0.0.0 \
    PUSH_PORT=8088 \
    PUSH_DATA_FILE=/app/data/state.json \
    APNS_PRIVATE_KEY_PATH=/run/secrets/apns.p8

USER node

EXPOSE 8088

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:' + (process.env.PUSH_PORT || 8088) + '/health').then(r => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1))"

CMD ["node", "server.js"]
