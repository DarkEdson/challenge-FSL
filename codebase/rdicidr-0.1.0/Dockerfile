FROM node:15-buster as builder

WORKDIR /app

COPY package*.json package-lock.json ./

RUN npm install

COPY . .

RUN 

FROM nginx:1.27-alpine

COPY --from=builder /app/build /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

