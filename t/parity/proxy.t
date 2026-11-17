#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx;
use IO::Socket::INET;
use Digest::SHA qw/sha256/;
use Time::HiRes qw/sleep time/;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $plain = join '', map { sha256(pack 'N', $_) } (0 .. 16383);
my $t = Test::Nginx->new()->has(qw/http proxy/);
$t->write_file('stream-body', $plain);
write_config($t, <<'EOF');
%%TEST_GLOBALS%%
daemon off;
error_log %%TESTDIR%%/error.log debug;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    gzip off;
    zstd on;
    zstd_types *;
    zstd_min_length 0;

    zstd_buffers 2 1k;
    server {
        listen 127.0.0.1:8080 sndbuf=8k;
        proxy_buffer_size 1k;
        proxy_buffers 4 1k;
        proxy_busy_buffers_size 2k;
        proxy_temp_path %%TESTDIR%%/proxy_temp;
        location /on/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering on;
        }
        location /off/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
        }
    }
}
EOF
$t->run_daemon(\&origin, port(8081), $t->testdir());
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->run();

for my $mode (qw/on off/) {
    for my $known (0, 1) {
        for my $encoding (encodings()) {
            my $key = "${mode}_${known}_${encoding}";
            $t->write_file("release-$key", '1');
            check_response($t, request("/$mode/?id=$key&known=$known", $encoding),
                $encoding, $plain, "$mode known=$known $encoding");
        }
    }

    for my $encoding (encodings()) {
        my $key = "slow_${mode}_${encoding}";
        $t->write_file("release-$key", '1');
        my $socket = client();
        print $socket "GET /$mode/?id=$key HTTP/1.1\r\nHost: localhost\r\n"
            . "Accept-Encoding: $encoding\r\nConnection: close\r\n\r\n";
        sleep 0.1;
        my $response = read_response($socket);
        close $socket;
        check_response($t, $response, $encoding, $plain,
            "$mode $encoding slow client");

        $key = "abort_${mode}_${encoding}";
        $t->write_file("release-$key", '1');
        $socket = client();
        print $socket "GET /$mode/?id=$key HTTP/1.1\r\nHost: localhost\r\n"
            . "Accept-Encoding: $encoding\r\n\r\n";
        sysread($socket, my $buffer, 512);
        close $socket;

        $key = "after_${mode}_${encoding}";
        $t->write_file("release-$key", '1');
        check_response($t, request("/$mode/?id=$key&known=1", $encoding),
            $encoding, $plain, "$mode $encoding after client abort");
    }
}

$t->stop();
my $log = $t->read_file('error.log');
like($log, qr/zstd filter yield/, 'proxy output yields to the event loop');
like($log, qr/buffered to a temporary file/,
    'buffered proxy response spills to disk under backpressure');
unlike($log, qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no proxy buffering or lifecycle errors');
undef $t;
done_testing();

sub client {
    my $socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',
        PeerPort => port(8080), Proto => 'tcp', Timeout => 5) or die $!;
    $socket->autoflush(1);
    return $socket;
}

sub read_response {
    my ($socket) = @_;
    my $response = '';
    my $deadline = time() + 8;
    while (time() < $deadline) {
        my $bits = '';
        vec($bits, fileno($socket), 1) = 1;
        next unless select($bits, undef, undef, 0.1);
        my $n = sysread($socket, my $part, 16384);
        last unless $n;
        $response .= $part;
    }
    return $response;
}

sub origin {
    exec 'python3', '-B', "$FindBin::Bin/lib/origin.py", @_;
    die "origin exec: $!";
}
