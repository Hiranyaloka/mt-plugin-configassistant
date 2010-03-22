package ConfigAssistant::Static;

use strict;

use MT;
use MT::FileMgr;
use File::Spec;

sub manual_run {
    # The manual run is something that the admin may need to use if they
    # haven't correctly set permissions on the support folder.
    my $app = shift;
    my (@messages, $message);
    
    # We need to look at all plugins and decide if they have registry
    # entries, and therefore static entries.
    for my $sig ( keys %MT::Plugins ) {
        my $plugin   = $MT::Plugins{$sig}{object};
        my $registry = $plugin->{registry};

        # Do *not* check static versions, because we want the static copy
        # to run for all plugins.
        if ($registry->{'static_version'}) {
            push @messages, 'Copying static files for <strong>'.$plugin->name.'</strong>...';
            # Build a hash of the directory structure within the static folder.
            my $static_dir = {};
            $static_dir->{'static'} = File::Spec->catfile($plugin->path, 'static');
            my $dir_hash = _build_file_hash($static_dir->{'static'});

            my $skip = $registry->{'skip_static'};
            my @skip_files;
            foreach my $item (@$skip) {
                push @skip_files, $item;
            }
            push @messages, _traverse_hash($dir_hash, $plugin, '', @skip_files);
        }
    }
    my $message = join('<br />', @messages);
    
    $app->build_page('copy_static_files.mtml', { status => $message, });
}

sub upgrade {
    my $self = shift;
    my $app  = MT->instance;

    use MT::ConfigMgr;
    my $cfg = MT::ConfigMgr->instance;

    # We need to look at all plugins and decide if they have registry
    # entries, and therefore static entries.
    for my $sig ( keys %MT::Plugins ) {
        my $plugin   = $MT::Plugins{$sig}{object};
        my $registry = $plugin->{registry};

        # Grab the plugin's static_version, and check if it's newer than the
        # version currently installed. If it is, then we want to install
        # the static files.
        my $static_version = $registry->{'static_version'} || '0';
        # The saved version
        my $ver = MT->config('PluginStaticVersion');
        my $saved_version = $ver->{$plugin->id} if $ver;
        
        if ($static_version > $saved_version) {
            $self->progress('Copying static files for <strong>'.$plugin->name.'</strong> to mt-static/support/plugins/...');

            # Create the plugin's directory.
            my $message = _make_dir($plugin->key);
            $self->progress($message);

            # Build a hash of the directory structure within the static folder.
            my $static_dir = {};
            $static_dir->{'static'} = File::Spec->catfile($plugin->path, 'static');
            my $dir_hash = _build_file_hash($static_dir->{'static'});

            my $skip = $registry->{'skip_static'};
            my @skip_files;
            foreach my $item (@$skip) {
                push @skip_files, $item;
            }

            # Process all of the files found in the static folder.
            my @messages = _traverse_hash($dir_hash, $plugin, '', @$skip);
            $message = join('<br />', @messages);
            $self->progress($message);

            # Update mt_config with the new static_version.
            my $plugin_id = $plugin->id;
            $cfg->set('PluginStaticVersion', $plugin_id.'='.$static_version, 1);
            $self->progress($self->translate_escape("Plugin '[_1]' upgraded successfully to version [_2] (static version [_3]).", $plugin->label, $plugin->version || '-', $static_version));
        }
    }
    # Always return true so that the upgrade can continue.
    1;
}

sub _build_file_hash {
    my $dir  = shift;
    return unless (defined $dir && -d $dir);
    $dir =~ s#\\#/#g;    # Win32 :-(
    my $dirth = {};

    opendir(DIR, $dir) || die "Unable to opendir $dir\n";
    my @files = grep {!/^\.\.?$/} readdir(DIR);
    closedir(DIR);
    map {$dirth->{$_} = (-d "$dir/$_" ? &_build_file_hash("$dir/$_") : '')} @files;

    return $dirth;
}



sub _traverse_hash {
    my $dir_hash = shift;
    my $plugin   = shift;
    my $dir      = shift;
    my @skip     = @_;
    my (@messages, $message);
    my $app = MT->instance;

    while ( my ($cur_item, $subfolders) = each (%$dir_hash) ) {
        if ($subfolders ne '') {
            # Create the specified directory
            my $dir = File::Spec->catfile($dir, $cur_item);
            my $dir_w_plugin = File::Spec->catfile($plugin->key, $dir);
            $message = _make_dir($dir_w_plugin);
            push @messages, $message;
            # Now investigate the next level of the registry, to see if 
            # another directory is needed, or if there are files to copy.
            my @result = _traverse_hash($dir_hash->{$cur_item}, $plugin, $dir, @skip);
            push @messages, @result;
        }
        else {
            # These are files. If it's *not* supposed to be skipped, copy it.
            # Assume that we *do* want to copy each file, 
            my $process_file = 1;
            foreach my $to_skip (@skip) {
                if ( $cur_item =~ m/$to_skip/i ) {
                    # This file is in the skip list, so don't copy.
                    $process_file = 0;
                }
            }
            if ($process_file) {
                my $src = File::Spec->catfile($plugin->path, 'static', $dir, $cur_item);
                my $dest = File::Spec->catfile($app->config('StaticFilePath'), 
                            'support', 'plugins', $plugin->key, $dir, $cur_item);
                $message = _write_file($src, $dest);
                push @messages, $message;
            }
        }
    }
    return @messages;
}

sub _make_dir {
    # Create the required directory.
    my $dir = shift;
    my $fmgr = MT::FileMgr->new('Local')
        or return MT::FileMgr->errstr;

    my $app = MT->instance;
    my $dir = File::Spec->catfile($app->config('StaticFilePath'), 'support', 'plugins', $dir);
    if ( $fmgr->mkpath($dir) ) {
        # Success!
        my $app = MT->instance;
        my $static_file_path = $app->config('StaticFilePath');
        $dir =~ s!$static_file_path/support/plugins/(.*)!$1!;
        return "Created folder $dir/.";
    }
    else {
        return '<span style="color: #990000;">'.$fmgr->errstr.'</span>';
    }
    return;
}

sub _write_file {
    # Actually copy the file from plugins/static/ to the mt-static/support/plugins/ area.
    my ($src, $dest) = @_;
    my $fmgr = MT::FileMgr->new('Local')
        or return MT::FileMgr->errstr;

    # Grab the file specified.
    my $src_data = $fmgr->get_data($src)
        or return '<span style="color: #990000;">'.$fmgr->errstr.'</span>';
    # Write the file to its new home, but only if some data was read.
    if ($src_data) {
        my $bytes = $fmgr->put_data($src_data, $dest)
            or return '<span style="color: #990000;">'.$fmgr->errstr.'</span>';
        # Only provide a "copied" message if the file was successfully written.
        if ($bytes) {
            my $app = MT->instance;
            my $static_file_path = $app->config('StaticFilePath');
            $dest =~ s!$static_file_path/support/plugins/(.*)!$1!;
            return "Copied $dest.";
        }
    }
    return;
}

1;

__END__
