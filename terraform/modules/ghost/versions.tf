 terraform {
   required_providers {
       docker-compose = {
           source  = "kreuzwerker/docker-compose"
           version = "~> 0.22.3"
       }
       docker = {
           source  = "kreuzwerker/docker"
           version = "~> 3.0.1"
       }
       nomad = {
           source  = "hashicorp/nomad"
           version = ">= 1.4.14"
       }
   }
 }
