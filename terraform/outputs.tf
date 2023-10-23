# Output the IP Address of the container
output "ip" {
    value = "${module.ghost.ip_address}"
}
# Output the name of the container
output "name" {
    value = "${module.ghost.name}"
}