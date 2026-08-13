//go:build !linux

package backend

import "errors"

type nativeNetworkNamespaceOperations struct{}

func (nativeNetworkNamespaceOperations) Create(_, _, _, _ string) error {
	return errors.New("network namespaces require Linux")
}

func (nativeNetworkNamespaceOperations) Delete(_ string) error {
	return errors.New("network namespaces require Linux")
}
