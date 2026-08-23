# CMake generated Testfile for 
# Source directory: /home/keni/picoquic
# Build directory: /home/keni/picoquic
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test(picoquic_ct "/home/keni/picoquic/picoquic_ct" "-S" "/home/keni/picoquic" "-n" "-r")
set_tests_properties(picoquic_ct PROPERTIES  _BACKTRACE_TRIPLES "/home/keni/picoquic/CMakeLists.txt;486;add_test;/home/keni/picoquic/CMakeLists.txt;0;")
add_test(picohttp_ct "/home/keni/picoquic/picohttp_ct" "-S" "/home/keni/picoquic" "-n" "-r")
set_tests_properties(picohttp_ct PROPERTIES  _BACKTRACE_TRIPLES "/home/keni/picoquic/CMakeLists.txt;488;add_test;/home/keni/picoquic/CMakeLists.txt;0;")
subdirs("_deps/picotls-build")
