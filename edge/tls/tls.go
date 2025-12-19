package tls

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"time"
)

// LoadOrSelfSign loads cert/key if present, otherwise generates a short-lived self-signed cert.
func LoadOrSelfSign(certPath, keyPath string) (tls.Certificate, error) {
	if fileExists(certPath) && fileExists(keyPath) {
		return tls.LoadX509KeyPair(certPath, keyPath)
	}
	return generateSelfSigned()
}

func ServerConfig(cert tls.Certificate, minTLS13 bool) *tls.Config {
	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"h2", "http/1.1"},
	}
	if minTLS13 {
		cfg.MinVersion = tls.VersionTLS13
	}
	cfg.GetConfigForClient = func(*tls.ClientHelloInfo) (*tls.Config, error) {
		// Hook for SNI-based per-tenant config (future).
		return nil, nil
	}
	return cfg
}

func ListenTLS(network, addr string, cfg *tls.Config) (net.Listener, error) {
	return tls.Listen(network, addr, cfg)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func generateSelfSigned() (tls.Certificate, error) {
	priv, _ := rsa.GenerateKey(rand.Reader, 2048)
	template := x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: "OLWSX-EDGE-SELF-SIGNED"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(30 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)})
	return tls.X509KeyPair(certPEM, keyPEM)
}