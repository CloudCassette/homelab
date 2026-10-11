#!/bin/bash

# Remove all stopped containers
docker container prune -f

# Remove unused images (dangling images)
docker image prune -f

# Remove unused networks
docker network prune -f

# Remove unused volumes (use with caution)
docker volume prune -f
