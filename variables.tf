# Defining Variables
variable "ghost_image" {
    description = "Image of Ghost"
    default = "ghost:latest"
}
variable "ghost_container_name" {
    description = "Name of Ghost Container"
    default = "blog"
}
variable "ext_port" {
    description = "External Port of Ghost"
    default = "80"
}