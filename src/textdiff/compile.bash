
# example: ./src/textdiff/compile.bash headers/*
#
# then run ./src/textdiff/test.bash headers/*

HEADER_LIST="$@"

# check that all headers exist somewhere in reductions.zig - this check is to
# make sure when new headers are added reductions.zig is updated
for i in $HEADER_LIST;
do
    grep -q `basename $i` src/textdiff/reductions.zig || { echo "couldn't find '`basename $i`' in reductions.zig, is it new?"; exit 1; }
done

if [ -d uh_workspace ];
then
    echo "directory uh_workspace already exists, need to remove it - rm -r uh_* ?"
    exit 1
fi

for i in $HEADER_LIST;
do
    echo "addHeaders $i"
    ./zig-out/bin/addHeaders $i || exit 1
done


echo "outputHeaders"
./zig-out/bin/outputHeaders uh_headers || exit 1


exit 0
