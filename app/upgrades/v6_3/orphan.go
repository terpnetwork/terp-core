package v6_3

import (
	"fmt"
	"os"
	"reflect"
	"unsafe"

	dbm "github.com/cosmos/cosmos-db"
	"github.com/cosmos/cosmos-sdk/baseapp"
	rootmulti "github.com/cosmos/cosmos-sdk/store/v2/rootmulti"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"

	"github.com/terpnetwork/terp-core/v6/app/iavl"
)

// StoreLoader drops orphaned b3-* IAVL bytes, then runs the SDK upgrade loader.
// v6.1 added those trees at 23191300. v6.2 stopped mounting them and left the
// bytes in application.db. Listing them in StoreUpgrades.Added sets initial
// version to this halt, and IAVL rejects a tree whose first version is earlier.
func StoreLoader(upgradeHeight int64, storeUpgrades *storetypes.StoreUpgrades) baseapp.StoreLoader {
	next := upgradetypes.UpgradeStoreLoader(upgradeHeight, storeUpgrades)
	return func(ms storetypes.CommitMultiStore) error {
		if upgradeHeight == ms.LastCommitID().Version+1 {
			db, err := commitMultiStoreDB(ms)
			if err != nil {
				return err
			}
			if _, err := DropOrphanDestStores(db); err != nil {
				return err
			}
		}
		return next(ms)
	}
}

// DropOrphanDestStores deletes s/k:b3-* prefixes that are absent from the
// latest CommitInfo. A dest name already in that commit is the post-upgrade
// tree and is left in place.
func DropOrphanDestStores(db dbm.DB) (map[string]int, error) {
	latest := rootmulti.GetLatestVersion(db)
	if latest == 0 {
		return map[string]int{}, nil
	}
	bz, err := db.Get([]byte(fmt.Sprintf("s/%d", latest)))
	if err != nil {
		return nil, fmt.Errorf("v6.3: read commit info %d: %w", latest, err)
	}
	if len(bz) == 0 {
		return nil, fmt.Errorf("v6.3: missing commit info %d", latest)
	}
	var info storetypes.CommitInfo
	if err := info.Unmarshal(bz); err != nil {
		return nil, fmt.Errorf("v6.3: unmarshal commit info %d: %w", latest, err)
	}
	mounted := make(map[string]struct{}, len(info.StoreInfos))
	for _, si := range info.StoreInfos {
		mounted[si.Name] = struct{}{}
	}

	dropped := make(map[string]int)
	for _, name := range iavl.DestStores() {
		if _, ok := mounted[name]; ok {
			fmt.Fprintf(os.Stderr, "v6.3: dest store %s is in commit %d; leaving it\n", name, latest)
			continue
		}
		n, err := deletePrefix(db, []byte("s/k:"+name+"/"))
		if err != nil {
			return dropped, fmt.Errorf("v6.3: drop orphan %s: %w", name, err)
		}
		dropped[name] = n
		if n > 0 {
			fmt.Fprintf(os.Stderr, "v6.3: dropped orphan dest store %s keys=%d commit=%d\n", name, n, latest)
		}
	}
	return dropped, nil
}

func deletePrefix(db dbm.DB, prefix []byte) (int, error) {
	end := prefixEnd(prefix)
	total := 0
	for {
		itr, err := db.Iterator(prefix, end)
		if err != nil {
			return total, err
		}
		batch := db.NewBatch()
		n := 0
		for ; itr.Valid() && n < 4096; itr.Next() {
			batch.Delete(append([]byte(nil), itr.Key()...))
			n++
		}
		iterErr := itr.Error()
		itr.Close()
		if iterErr != nil {
			_ = batch.Close()
			return total, iterErr
		}
		if n == 0 {
			_ = batch.Close()
			return total, nil
		}
		if err := batch.WriteSync(); err != nil {
			_ = batch.Close()
			return total, err
		}
		_ = batch.Close()
		total += n
	}
}

func prefixEnd(prefix []byte) []byte {
	end := append([]byte(nil), prefix...)
	for i := len(end) - 1; i >= 0; i-- {
		if end[i] < 0xff {
			end[i]++
			return end[:i+1]
		}
	}
	return nil
}

func commitMultiStoreDB(ms storetypes.CommitMultiStore) (dbm.DB, error) {
	v := reflect.ValueOf(ms)
	if v.Kind() != reflect.Ptr || v.IsNil() {
		return nil, fmt.Errorf("v6.3: commit multistore is not a pointer")
	}
	f := v.Elem().FieldByName("db")
	if !f.IsValid() {
		return nil, fmt.Errorf("v6.3: commit multistore has no db field")
	}
	db, ok := reflect.NewAt(f.Type(), unsafe.Pointer(f.UnsafeAddr())).Elem().Interface().(dbm.DB)
	if !ok || db == nil {
		return nil, fmt.Errorf("v6.3: commit multistore db is empty")
	}
	return db, nil
}
