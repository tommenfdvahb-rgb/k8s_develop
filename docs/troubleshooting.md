# Troubleshooting

## Port already in use

Symptoms:
- precheck reports 6443 or 10250 or 2379 is occupied

Actions:
- run: `ss -lntp | grep -E ':6443 |:10250 |:2379 '`
- stop conflicting services before deployment

## Offline package validation failed

Symptoms:
- install script exits with tar validation error

Actions:
- verify file exists and path in OFFLINE_TAR is correct
- run: `tar -tf "$OFFLINE_TAR" | head`

## SSH connectivity failure

Symptoms:
- check_ssh reports port unreachable

Actions:
- verify network routing and security group/firewall rules
- verify node IP and SSH port
- run: `nc -z -w5 <node-ip> <port>`

## sealos not found

Symptoms:
- install script exits with missing sealos binary

Actions:
- place `sealos` in the same directory as install.sh, or install to PATH
- run: `sealos version`

## kubectl check failed after installation

Symptoms:
- post_check reports kubectl error

Actions:
- confirm kubeconfig context
- run: `kubectl get nodes -o wide`
- run: `kubectl get pods -A`
