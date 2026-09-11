echo "--- hostname ---";   hostnamectl --static
echo "--- machine-id ---"; cat /etc/machine-id; readlink -f /var/lib/dbus/machine-id
echo "--- ip ---";         ip -4 -br addr show scope global
echo "--- ssh keys ---";   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
echo "--- k3s node ---";   kubectl get node -o wide
echo "--- k3s cert ---";   openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
                             | openssl x509 -noout -ext subjectAltName
echo "--- instanz ---";    grep -E '^(DOMAIN|INSTANCE_SLUG)=' /etc/civitas/deploy.env
echo "--- namespace ---";  kubectl get ns