#!/bin/bash

if pgrep -f external_miner.py > /dev/null;
then
        echo ERROR: external_miner.py is running. stop manually and rerun the test!
        echo for example: pkill -f external_miner.py
        exit 1
fi

cpu_count="$(cat /proc/cpuinfo | grep "physical id" | sort | uniq | wc -l)"
cpu_cores="$(cat /proc/cpuinfo | grep "siblings" | uniq | tr -d ' ' | cut -d: -f2)"
cpu_type="$(cat /proc/cpuinfo | grep "model name" | uniq | tr -s ' ' | cut -d: -f2)"
cpu_cores_total=6

if [ "$cpu_count" -gt 0 ] ; then
  for i in $(seq 1 $cpu_count) ; do
    cpu_spec_type="$(echo "$cpu_type" | head -n$i | tail -n1)"
    echo -n "   CPU$i:$cpu_spec_type"
    cpu_spec_cores="$(echo "$cpu_cores" | head -n$i | tail -n1)"
    if [ "$cpu_spec_cores" -gt 1 ] ; then
      echo " (Cores $cpu_spec_cores)"
    else
      echo
    fi
  done
else
  echo "   CPU: $cpu_type"
fi

suffix=$(cat /dev/urandom | tr -dc 'A-F0-9' | fold -w 8 | head -n 1)
script_name="QKC_$suffix.py"


############### http://redsymbol.net/articles/bash-exit-traps/
#### cleanup on exit
function _finish {
        echo caught trap. cleaning up
        pkill -f $script_name > /dev/null && echo killed children
        rm -rf *_$suffix.log
        exit 10
}
trap _finish SIGINT SIGTERM
#### cleanup 

cat << 'EOF' > $script_name
import bisect
import ctypes
import time
import unittest
from typing import Dict, List

from Crypto.Hash import keccak

FNV_PRIME_64 = 0x100000001b3
UINT64_MAX = 2 ** 64

CACHE_ENTRIES = 1024 * 64
ACCESS_ROUND = 64
WORD_BYTES = 8


def serialize_hash(h):
    return b"".join([x.to_bytes(WORD_BYTES, byteorder="little") for x in h])


def deserialize_hash(h):
    return [
        int.from_bytes(h[i : i + WORD_BYTES], byteorder="little")
        for i in range(0, len(h), WORD_BYTES)
    ]


def hash_words(h, sz, x):
    if isinstance(x, list):
        x = serialize_hash(x)
    y = h(x)
    return deserialize_hash(y)


def serialize_cache(ds):
    return "".join([serialize_hash(h) for h in ds])


serialize_dataset = serialize_cache

# sha3 hash function, outputs 64 bytes


def sha3_512(x):
    return hash_words(lambda v: keccak.new(digest_bits=512, data=v).digest(), 64, x)


def sha3_256(x):
    return hash_words(lambda v: keccak.new(digest_bits=256, data=v).digest(), 32, x)


def fnv64(v1, v2):
    return ((v1 * FNV_PRIME_64) ^ v2) % UINT64_MAX


def make_cache(entries, seed):
    cache = []
    cache_set = set()

    for i in range(entries // 8):
        o = sha3_512(seed + i.to_bytes(4, byteorder="big"))
        for e in o:
            if e not in cache_set:
                cache.append(e)
                cache_set.add(e)

    cache.sort()
    return cache


def select(data, n):
    left = 0
    right = len(data)

    while True:
        pivot = data[left]
        i = left + 1
        e = right
        while i < e:
            if pivot < data[i]:
                e = e - 1
                tmp = data[e]
                data[e] = data[i]
                data[i] = tmp
            else:
                i = i + 1
        i = i - 1
        data[left] = data[i]
        data[i] = pivot

        if i == n:
            return pivot
        elif n < i:
            right = i
        else:
            left = i + 1


class TestSelect(unittest.TestCase):
    def test_simple(self):
        data = [1, 0, 2, 4, 3]
        self.assertEqual(select(data[:], 0), 0)
        self.assertEqual(select(data[:], 1), 1)
        self.assertEqual(select(data[:], 2), 2)
        self.assertEqual(select(data[:], 3), 3)
        self.assertEqual(select(data[:], 4), 4)

    def test_cache(self):
        data = make_cache(128, bytes())
        sdata = data[:]
        sdata.sort()
        for i in range(len(data)):
            self.assertEqual(select(data[:], i), sdata[i])


def list_to_uint64_array(l):
    array = (ctypes.c_uint64 * len(l))()
    for i in range(len(l)):
        array[i] = l[i]
    return array


class QkcHashCache:
    def __init__(self, native, ptr):
        self._ptr = ptr
        self._native = native

    def __del__(self):
        self._native._cache_destroy(self._ptr)


class QkcHashNative:
    def __init__(self, lib_path="libqkchash.so"):
        self._lib = ctypes.CDLL(lib_path)

        self._hash_func = self._lib.qkc_hash
        self._hash_func.restype = None
        self._hash_func.argtypes = (
            ctypes.c_void_p,  # cache pointer
            ctypes.POINTER(ctypes.c_uint64),  # input seed
            ctypes.POINTER(ctypes.c_uint64),
        )  # output result

        self._cache_create = self._lib.cache_create
        self._cache_create.restype = ctypes.c_void_p
        self._cache_create.argtypes = (
            ctypes.POINTER(ctypes.c_uint64),  # cache array pointer
            ctypes.c_uint32,
        )  # cache size

        self._cache_destroy = self._lib.cache_destroy
        self._cache_destroy.restype = None
        self._cache_destroy.argtypes = (ctypes.c_void_p,)

    def make_cache(self, entries, seed):
        cache = list_to_uint64_array(make_cache(entries, seed))
        ptr = self._cache_create(cache, len(cache))
        return QkcHashCache(self, ptr)

    def dup_cache(self, cache):
        return cache

    def calculate_hash(self, header, nonce, cache):
        s = sha3_512(header + nonce[::-1])
        seed = list_to_uint64_array(s)
        result = (ctypes.c_uint64 * 4)()

        self._hash_func(cache._ptr, seed, result)

        return {
            "mix digest": serialize_hash(result),
            "result": serialize_hash(sha3_256(s + result[:])),
        }


def qkchash(header: bytes, nonce: bytes, cache: List) -> Dict[str, bytes]:
    s = sha3_512(header + nonce[::-1])
    lcache = cache[:]
    lcache_set = set(cache)

    mix = []
    for i in range(2):
        mix.extend(s)

    for i in range(ACCESS_ROUND):
        new_data = []

        p = fnv64(i ^ s[0], mix[i % len(mix)])
        for j in range(len(mix)):
            # Find the pth element and remove it
            remove_idx = p % len(lcache)
            new_data.append(lcache[remove_idx])
            lcache_set.remove(lcache[remove_idx])
            del lcache[remove_idx]

            # Generate random data and insert it
            p = fnv64(p, new_data[j])
            if p not in lcache_set:
                bisect.insort(lcache, p)
                lcache_set.add(p)

            # Find the next element
            p = fnv64(p, new_data[j])

        for j in range(len(mix)):
            mix[j] = fnv64(mix[j], new_data[j])

    cmix = []
    for i in range(0, len(mix), 4):
        cmix.append(fnv64(fnv64(fnv64(mix[i], mix[i + 1]), mix[i + 2]), mix[i + 3]))
    return {
        "mix digest": serialize_hash(cmix),
        "result": serialize_hash(sha3_256(s + cmix)),
    }


class TestQkcHash(unittest.TestCase):
    def test_hash_vectors(self):
        cache = make_cache(CACHE_ENTRIES, bytes())
        self.assertEqual(len(cache), CACHE_ENTRIES)

        v0 = [11967621512234744254, 11712119753881699857,
              4190255959603841725, 6654395615551794006]
        h0 = qkchash(bytes(), bytes(), cache)
        self.assertEqual(h0["mix digest"], serialize_hash(v0))

        v1 = [12754842531904701011, 8384861435613290118,
              2739024099562295228, 4448910328080420635]
        h1 = qkchash(b"Hello World!", bytes(), cache)
        self.assertEqual(h1["mix digest"], serialize_hash(v1))


def test_qkchash_perf():
####    N = 10000
####    start_time = time.time()
####    cache = make_cache(CACHE_ENTRIES, bytes())
####    used_time = time.time() - start_time
####    print("make_cache time: %.2f" % (used_time))
####
####    start_time = time.time()
####    h0 = []
####    for nonce in range(N):
####        if nonce>0:
####            if nonce%(N/20)==0:
####                used_time = time.time() - start_time
####                done_percent = (nonce/N)*100
####                hashrate = nonce / used_time
####                print("Python: %.2f sec done %.2f percent with hashrate=%.2f" % (used_time, done_percent, hashrate))
####        h0.append(qkchash(bytes(4), nonce.to_bytes(4, byteorder="big"), cache))
####    used_time = time.time() - start_time
####    print(
####        "Python version, time used: %.2f, N=%d, hashes per sec: %.2f"
####        % (used_time, N, N / used_time)
####    )
####
    # Native version
    native = QkcHashNative()
    cache = native.make_cache(CACHE_ENTRIES, bytes())

    start_time = time.time()
    h1 = []
    N = 10000
    for nonce in range(N):
        if nonce>0:
            if nonce%(N/20)==0:
                used_time = time.time() - start_time
                done_percent = (nonce/N)*100
                hashrate = nonce / used_time
                print("Native: %.2f sec done %.2f percent with hashrate=%.2f" % (used_time, done_percent, hashrate))
        dup_cache = native.dup_cache(cache)
        h1.append(
            native.calculate_hash(
                bytes(4), nonce.to_bytes(4, byteorder="big"), dup_cache
            )
        )
    used_time = time.time() - start_time
    print(
        "Native version, time used: %.2f, N=%d, hashes per sec: %.2f"
        % (used_time, N, N / used_time)
    )

####    print("Equal: ", h0 == h1[0 : len(h0)])


def print_test_vector():
    cache = make_cache(CACHE_ENTRIES, bytes())
    print("Cache size: ", len(cache))
    print("Hash of empty:")
    h0 = qkchash(bytes(), bytes(), cache)
    print(deserialize_hash(h0["mix digest"]))

    print("Hash of Hello World!:")
    h1 = qkchash(b"Hello World!", bytes(), cache)
    print(deserialize_hash(h1["mix digest"]))


if __name__ == "__main__":
    print_test_vector()
    test_qkchash_perf()
EOF

echo starting multi QKCHASH test with $cpu_cores_total threads:

if [ ! -d qkchash/ ];
then
        echo "qkchash folder not found; exit!"
        exit 2
fi


for i in $(seq 1 $cpu_cores_total);
do
        echo $(date) starting $i
        logname="test$i""_$suffix"".log"
        LD_LIBRARY_PATH=./qkchash/ python3 -u $script_name &> $logname & children_pids+=( "$!" )
done

echo started ${#children_pids[@]} children

while :
do
        if pgrep -f $script_name > /dev/null;
        then
                echo children are still running. their last outputs:
                tail -n 1 test*_$suffix.log
                sleep 10
        else
                echo children are dead...
                echo found $(grep "Native version, time used" *_$suffix.log | wc -l) finish lines
                grep "Native version, time used:" *_$suffix.log \
                | sed 's/.*hashes per sec: //g' \
                | awk '{sum+=sprintf("%f",$1)}END{printf "threads:\t\t%d\ntotal hashrate:\t\t%.2f\nsingle thread hashrate:\t%.2f\n",NR,sum,sum/NR}'
                echo "remove bodies:" && rm $script_name *_$suffix.log && echo success... || echo oops...

                exit
        fi
done
