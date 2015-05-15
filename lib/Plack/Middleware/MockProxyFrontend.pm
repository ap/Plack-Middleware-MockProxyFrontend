use 5.014;
use strict;
use warnings;

package Plack::Middleware::MockProxyFrontend;

# ABSTRACT: virtualhost-aware PSGI app developer tool

use parent 'Plack::Middleware';
use Plack::Util::Accessor qw( host_acceptor http_server _ssl_context );
use URI::Split ();
use IO::Socket::SSL ();

sub new {
	my $class = shift;
	my $self = $class->SUPER::new( @_ );

	$self->_ssl_context( IO::Socket::SSL::SSL_Context->new(
		( map { /^SSL_/ ? ( $_, $self->{ $_ } ) : () } keys %$self ),
		SSL_server => 1,
	) );

	$self->http_server( do {
		require HTTP::Server::PSGI;
		HTTP::Server::PSGI->new;
	} ) unless $self->http_server;

	$self;
}

sub call {
	my $self = shift;
	my $env = shift;

	my ( $scheme, $auth, $path, $query, $client_fh );

	if ( 'CONNECT' eq $env->{'REQUEST_METHOD'} ) {
		$client_fh = $env->{'psgix.io'}
			or return [ 405, [], ['CONNECT is not supported'] ];
		$auth = $env->{'REQUEST_URI'};
		$scheme = 'https';
	}
	else {
		( $scheme, $auth, $path, $query ) = URI::Split::uri_split $env->{'REQUEST_URI'};
		return [ 400, [], ['Not a proxy request'] ]
			if not $scheme
			or $scheme !~ /\Ahttps?\z/i;
	}

	my ( $host, $port ) = ( lc $auth ) =~ m{^(?:.+\@)?(.+?)(?::(\d+))?$};
	$port //= 'https' eq lc $scheme ? 443 : 80;

	my $acceptor = $self->host_acceptor;
	return [ 403, [], ['Refused by MockProxyFrontend'] ]
		if $acceptor and not grep $acceptor->( $host ), $host;

	$client_fh
		? sub {
			my $writer = shift->( [ 200, [] ] );

			my $conn = IO::Socket::SSL->new_from_fd(
				fileno $client_fh,
				SSL_server    => 1,
				SSL_reuse_ctx => $self->_ssl_context,
			);

			$self->http_server->handle_connection( {
				'psgi.url_scheme' => $scheme,
				SERVER_NAME       => $host,
				SERVER_PORT       => $port,
				SCRIPT_NAME       => '',
				'psgix.io'        => $conn,
				# pass-through
				REMOTE_ADDR    => $env->{'REMOTE_ADDR'},
				REMOTE_PORT    => $env->{'REMOTE_PORT'},
				'psgi.errors'  => $env->{'psgi.errors'},
				'psgi.version' => $env->{'psgi.version'},
				# constants
				'psgi.run_once'        => Plack::Util::TRUE,
				'psgi.multithread'     => Plack::Util::FALSE,
				'psgi.multiprocess'    => Plack::Util::FALSE,
				'psgi.streaming'       => Plack::Util::TRUE,
				'psgi.nonblocking'     => Plack::Util::FALSE,
				'psgix.input.buffered' => Plack::Util::TRUE,
			}, $conn, $self->app );

			$conn->close;
			$writer->close;
		}
		: $self->app->( {
			%$env,
			'psgi.url_scheme' => $scheme,
			HTTP_HOST         => $host,
			SERVER_PORT       => $port,
			REQUEST_URI       => ( join '?', $path, $query // () ),
			PATH_INFO         => $path =~ s!%([0-9]{2})!chr hex $1!rge,
		} );
}

1;

__END__

=head1 SYNOPSIS

 # in app.psgi
 use Plack::Builder;
 
 builder {
     enable 'MockProxyFrontend',
        SSL_key_file  => 'key.pem',
        SSL_cert_file => 'cert.pem';
     $app;
 };

=head1 DESCRIPTION

This middleware implements the HTTP proxy protocolE<hellip> without the proxy:
it just passes the requests down to the wrapped PSGI application.
This is useful during development of PSGI applications that do virtual hosting
(i.e. that dispatch on hostname somewhere).

After enabling this middleware, you can set C<localhost:5000> (or wherever your
development server listening) as the proxy in your browser and navigate to e.g.
C<https://some.example.com>, and that request will hit your application instead
of going out to the internet. But the request will look to your application as
though it was actually sent to that domain, and likewise the response will look
to the browser as though it actually came from that domain.

=head1 CONFIGURATION OPTIONS

=over 4

=item C<SSL_*>

Configuration options for L<IO::Socket::SSL> that will be used to construct an
SSL context.

You don't need to pass any of these unless you need SSL support.
If you do, you will probably want to pass C<SSL_key_file> and C<SSL_cert_file>.

=item C<host_acceptor>

A function that will be called to decide whether to serve a request.
If it returns false, the request will be refused, otherwise it will be served.
The function will be passed with the lowecased hostname from the request,
both as its sole argument and in C<$_>. E.g.:

 enable 'MockProxyFrontend',
     host_acceptor => sub { 'webmonkeys.io' eq $_ };

Defaults to accepting all requests.

=item C<http_server>

An object that responds to C<< $self->handle_connection( $env, $socket, $app ) >>.
This will be passed the connection from C<CONNECT> requests. E.g.:

 enable 'MockProxyFrontend',
     http_server => do {
         require Starlet::Server;
         Starlet::Server->new
     };

Defaults to an instance of L<HTTP::Server::PSGI>.

=back

=head1 BUGS AND LIMITATIONS

Error checking and attitude toward security is lackadaiscal.

There are B<NO TESTS> because I wouldn't know how to write them.

This was written as a developer tool, not for deployment anywhere that could be
described as production. Otherwise I wouldn't be releasing it in this state.

Use at your own risk.

Mind you, I am anything but opposed to fixing these problems E<ndash> I am just
not losing sleep over them. Patches welcome and highly appreciated.
