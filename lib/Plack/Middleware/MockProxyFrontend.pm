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
