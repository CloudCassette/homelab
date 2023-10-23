# Downloading the ghost image
resource "docker_image" "ghost" {
    name = "${var.ghost_image}"
}

# Start the Container
resource "docker_container" "ghost" {
    name  = "${var.ghost_container_name}"
    image = "${docker_image.ghost.latest}"
    ports {
        internal = "2368"
        external = "${var.ext_port}"
    }
}