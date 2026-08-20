# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /source

COPY SafeLane.DemoApi.slnx ./
COPY src/SafeLane.DemoApi/SafeLane.DemoApi.csproj src/SafeLane.DemoApi/
RUN dotnet restore src/SafeLane.DemoApi/SafeLane.DemoApi.csproj

COPY src/SafeLane.DemoApi/ src/SafeLane.DemoApi/
RUN dotnet publish src/SafeLane.DemoApi/SafeLane.DemoApi.csproj \
    --configuration Release \
    --no-restore \
    --output /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine AS final
ARG APP_VERSION=dev
ARG GIT_SHA=unknown

ENV ASPNETCORE_HTTP_PORTS=8080 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA}

WORKDIR /app
COPY --from=build --chown=$APP_UID:$APP_UID /app ./
USER $APP_UID
EXPOSE 8080

ENTRYPOINT ["dotnet", "SafeLane.DemoApi.dll"]
