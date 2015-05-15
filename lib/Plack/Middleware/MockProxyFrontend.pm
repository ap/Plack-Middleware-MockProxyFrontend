use 5.014;
use strict;
use warnings;

package Plack::Middleware::MockProxyFrontend;

# ABSTRACT: virtualhost-aware PSGI app developer tool

use parent 'Plack::Middleware::Proxy::Connect';
use Plack::Util::Accessor qw( accept_host connect_addr );
use URI ();

sub call {
	my $self = shift;
	my $env = shift;

	my ( $uri, $scheme, $host, $connect_addr, $acceptor );

	if ( 'CONNECT' eq $env->{'REQUEST_METHOD'} ) {
		$connect_addr = $self->connect_addr
			// return [ 405, [], ['Method not implemented'] ];
		$host = lc $env->{'REQUEST_URI'} =~ s/:[0-9]+\z//r;
	}
	else {
		$uri = URI->new( $env->{'REQUEST_URI'} );
		$scheme = $uri->scheme;
		return $self->app->( $env ) if not $scheme;
		$host = lc $uri->host;
	}

	return [ 403, [], ['Refused by MockProxyFrontend'] ]
		if $acceptor = $self->accept_host
		and not grep $acceptor->( $host ), $host;

	defined $connect_addr
		? $self->SUPER::call( { %$env, REQUEST_URI => $connect_addr } )
		: $self->app->( {
			%$env,
			'psgi.url_scheme' => $scheme,
			HTTP_HOST         => $host,
			SERVER_PORT       => $uri->port,
			REQUEST_URI       => $uri->path_query,
			PATH_INFO         => $uri->path =~ s!%([0-9]{2})!chr hex $1!rge,
		} );
}

1;
