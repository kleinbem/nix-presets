# `os dx::*` — developer experience (distrobox).

# Create a Fedora development distrobox.
create-fedora name="fedora-dev":
    distrobox create --image registry.fedoraproject.org/fedora:40 --name {{name}}

# Create an Ubuntu development distrobox.
create-ubuntu name="ubuntu-dev":
    distrobox create --image ubuntu:24.04 --name {{name}}

# Enter a distrobox.
enter name="fedora-dev":
    distrobox enter {{name}}

# List all distroboxes.
list:
    distrobox list

# Update all distroboxes.
update:
    distrobox upgrade --all
