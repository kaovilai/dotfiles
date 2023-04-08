alias code='open -a Visual\ Studio\ Code'
alias ghd='open -a GitHub\ Desktop'
alias finder='open -R'
alias idlesleeppreventers='pmset -g assertions'
alias edgedev='open -a Microsoft\ Edge\ Dev'
alias edge='open -a Microsoft\ Edge'

PATH=$PATH:/Users/tiger/Library/Python/3.9/bin

function podmanMachineReset(){
    podman machine stop; podman machine rm --save-image --force; podman machine init --cpus 6 --disk-size 30 --memory 1500 --now
}

function setTTLforHotspot(){
    sudo sysctl -w net.inet.ip.ttl=65
}