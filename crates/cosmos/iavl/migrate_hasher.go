package iavl

import (
	"errors"
	"fmt"
)

// CopyRehash exports src (any hasher) and imports into dst, which must be empty
// and already configured with the destination hasher (e.g. BLAKE3).
//
// Import rebuilds hashes from ExportNode preimages, so dst's hasher is what
// the new inner/leaf hashes use. Leaf key/value bytes are unchanged.
// Historical versions of src are not copied — only the latest tree.
//
// This is the IAVL-level primitive for a coordinated hash-algorithm upgrade.
func CopyRehash(src, dst *MutableTree) error {
	if src == nil || dst == nil {
		return errors.New("CopyRehash: nil tree")
	}
	if !dst.IsEmpty() {
		return errors.New("CopyRehash: destination must be empty")
	}

	version, err := src.GetLatestVersion()
	if err != nil {
		return err
	}
	if version == 0 {
		return nil
	}

	it, err := src.GetImmutable(version)
	if err != nil {
		return fmt.Errorf("CopyRehash: get immutable: %w", err)
	}

	exporter, err := it.Export()
	if err != nil {
		return fmt.Errorf("CopyRehash: export: %w", err)
	}
	defer exporter.Close()

	importer, err := dst.Import(version)
	if err != nil {
		return fmt.Errorf("CopyRehash: import: %w", err)
	}

	for {
		node, err := exporter.Next()
		if errors.Is(err, ErrorExportDone) {
			break
		}
		if err != nil {
			importer.Close()
			return fmt.Errorf("CopyRehash: export next: %w", err)
		}
		if err := importer.Add(node); err != nil {
			importer.Close()
			return fmt.Errorf("CopyRehash: import add: %w", err)
		}
	}

	if err := importer.Commit(); err != nil {
		return fmt.Errorf("CopyRehash: commit: %w", err)
	}
	return nil
}
