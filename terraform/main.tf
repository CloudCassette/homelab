module "ghost" {
    source = "./modules/ghost"
    ghost_image = var.ghost_image
    ghost_container_name = var.ghost_container_name
    ext_port = var.ext_port
}