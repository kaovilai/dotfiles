# znap function updateDockerHostEnv() {
#   command -v podman 2>&1 > /dev/null && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
# }

# not needed when eval $(crc podman-env)
# command -v podman && DOCKER_HOST=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')