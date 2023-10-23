# Output the IP address of the container
output "ip" {
    value = "${docker_container.ghost.ip_address}"
}

# Output the name of the container
output "name" {
    value = "${docker_container.ghost.name}"
}