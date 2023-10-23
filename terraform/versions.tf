 terraform {
   required_providers {
       required_version = ">= 1.0.0"
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