
HEADER_LIST="$@"

for i in $HEADER_LIST;
do
    echo "testHeaders $i"
    ./zig-out/bin/testHeaders uh_headers uh_test $i
    diff -uBwr uh_norm/$(basename $i) uh_test | grep -v "Only in" > uh_diff
    if [ -s uh_diff ]
    then
        echo "failed: diff -uBwr uh_norm/$(basename $i) uh_test"
        exit 1
    fi
done

exit 0
