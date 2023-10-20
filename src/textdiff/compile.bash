
# example: ./src/textdiff/compile.bash headers/m68k-linux*
#
# then run ./src/textdiff/test.bash headers/m68k-linux*

HEADER_LIST="$@"

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
