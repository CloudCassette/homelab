# homelab
Just a punk doing DevOps at home.

This is where I keep all the configurations for my homelab.

## 🏗️ **Infrastructure Architecture**

### **Repository Strategy**
- **🏠 This repo (homelab)**: Terraform infrastructure provisioning
- **🎸 [orlandopunx-infrastructure](https://github.com/CloudCassette/orlandopunx-infrastructure)**: Ansible service configuration

### **Technology Stack**
- **Terraform**: Infrastructure provisioning and base resource creation
- **Ansible**: Service configuration and application deployment  
- **Docker**: Container runtime with custom Steam Dock storage
- **Portainer**: Container management UI
- **Cloudflare Tunnels**: Secure external access with SSL termination

## 📁 **Current Modules**

### **Ghost Module** (`terraform/modules/ghost/`)
- Base Ghost container configuration
- Configurable ports and networking
- Integration ready for Ansible configuration management

## 🔗 **Service Integration**

### **Terraform → Ansible Flow**
1. **Terraform**: Provisions base infrastructure and Ghost containers
2. **Ansible**: Configures services, nginx, domains, and application settings
3. **Portainer**: Provides runtime management and monitoring

### **Current Deployments**
Managed by the orlandopunx-infrastructure Ansible configuration:
- **cloudcassette.blog**: Personal blog (port 2368)
- **orlandogirlsrockcamp.com**: Girls Rock Camp blog (port 2369) *ready for restoration*
- **tamtamthesandwichman.com**: Sandwich Man blog (port 2370) *planned*
- **godless-america.com**: Godless America blog (port 2371) *planned*

## 🚀 **Usage**

### **Infrastructure Provisioning**
```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

### **Service Configuration**  
```bash
cd ../orlandopunx-infrastructure/ansible/
ansible-playbook playbooks/site.yml --ask-vault-pass
```

## 🔧 **Development**

### **Adding New Services**
1. Create Terraform module in this repo
2. Create Ansible role in orlandopunx-infrastructure repo  
3. Deploy via Terraform → Ansible workflow

**Infrastructure provisioning and configuration management working together!** 🎸⚡
