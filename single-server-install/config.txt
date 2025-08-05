#!/bin/bash

# MongoDB Configuration
MONGODB_REPLICA_SET_MODE="primary"
MONGODB_REPLICA_SET_NAME="rs0"
MONGODB_REPLICA_SET_KEY="rs0key"
MONGODB_PORT_NUMBER="27017"
MONGODB_INITIAL_PRIMARY_HOST="mongodb"
MONGODB_INITIAL_PRIMARY_PORT_NUMBER="27017"
MONGODB_ADVERTISED_HOSTNAME="mongodb"
MONGODB_ENABLE_JOURNAL="true"
MONGODB_ROOT_PASSWORD="rootpass"
MONGODB_USERNAME="unicchat_admin"
MONGODB_PASSWORD="secure_password_123"
MONGODB_DATABASE="unicchat_db"

# Appserver Configuration
ROOT_URL="http://localhost:3000"
PORT="3000"
DEPLOY_METHOD="docker"
UNIC_SOLID_HOST="http://$(hostname -I | awk '{print $1}'):8881"

# Solid Configuration
INIT_CONFIG_NAMES="{Mongo}"
PLUGINS_ATTACH="'UniAct Mongo Logger UniVault Tasker'"



