
if [ -d uh_workspace ];
then
    echo "directory uh_workspace already exists, need to remove it - rm -r uh_* ?"
    exit 1
fi


HEADER_LIST=""
#HEADER_LIST="$HEADER_LIST headers/i386-linux-musl"
#HEADER_LIST="$HEADER_LIST headers/i486-linux-gnu.2.32"
#HEADER_LIST="$HEADER_LIST headers/i486-linux-gnu.2.33"
#HEADER_LIST="$HEADER_LIST headers/i486-linux-gnu.2.34"
#HEADER_LIST="$HEADER_LIST headers/i486-linux-gnu.2.35"
#HEADER_LIST="$HEADER_LIST headers/i486-linux-gnu.2.36"
#HEADER_LIST="$HEADER_LIST headers/i586-linux-gnu.2.32"
#HEADER_LIST="$HEADER_LIST headers/i586-linux-gnu.2.33"
#HEADER_LIST="$HEADER_LIST headers/i586-linux-gnu.2.34"
#HEADER_LIST="$HEADER_LIST headers/i586-linux-gnu.2.35"
#HEADER_LIST="$HEADER_LIST headers/i586-linux-gnu.2.36"
#HEADER_LIST="$HEADER_LIST headers/i686-linux-gnu.2.32"
#HEADER_LIST="$HEADER_LIST headers/i686-linux-gnu.2.33"
#HEADER_LIST="$HEADER_LIST headers/i686-linux-gnu.2.34"
#HEADER_LIST="$HEADER_LIST headers/i686-linux-gnu.2.35"
#HEADER_LIST="$HEADER_LIST headers/i686-linux-gnu.2.36"
#HEADER_LIST="$HEADER_LIST headers/ia64-linux-gnu.2.32"
#HEADER_LIST="$HEADER_LIST headers/ia64-linux-gnu.2.33"
#HEADER_LIST="$HEADER_LIST headers/ia64-linux-gnu.2.34"
#HEADER_LIST="$HEADER_LIST headers/ia64-linux-gnu.2.35"
#HEADER_LIST="$HEADER_LIST headers/ia64-linux-gnu.2.36"

HEADER_LIST="$HEADER_LIST headers/x86_64-freebsd.12.3-gnu"
HEADER_LIST="$HEADER_LIST headers/x86_64-freebsd.13.1-gnu"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu.2.32"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu.2.33"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu.2.34"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu.2.35"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu.2.36"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu-x32.2.32"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu-x32.2.33"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu-x32.2.34"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu-x32.2.35"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-gnu-x32.2.36"
HEADER_LIST="$HEADER_LIST headers/x86_64-linux-musl"
HEADER_LIST="$HEADER_LIST headers/x86_64-macos.11-none"
HEADER_LIST="$HEADER_LIST headers/x86_64-macos.12-none"
HEADER_LIST="$HEADER_LIST headers/x86_64-macos.13-none"
HEADER_LIST="$HEADER_LIST headers/x86-freebsd.12.3-gnu"
HEADER_LIST="$HEADER_LIST headers/x86-freebsd.13.1-gnu"

for i in $HEADER_LIST;
do
    echo "addHeaders $i"
    ./zig-out/bin/addHeaders $i || exit 1
done


echo "outputHeaders"
./zig-out/bin/outputHeaders uh_headers || exit 1


for i in $HEADER_LIST;
do
    echo "testHeaders $i"
    ./zig-out/bin/testHeaders uh_headers uh_test $i
    diff -uBwr $i uh_test | grep -v "Only in" > uh_diff
    if [ -s uh_diff ]
    then
        echo "failed: diff -uBwr $i uh_test"
        exit 1
    fi
done

exit 0
