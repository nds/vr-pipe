use VRPipe::Base;

class VRPipe::Steps::bam_merge extends VRPipe::Steps::picard {
    around options_definition {
        return { %{$self->$orig},
                 merge_sam_files_options => VRPipe::StepOption->get(description => 'options for picard MergeSamFiles', optional => 1, default_value => 'VALIDATION_STRINGENCY=SILENT'),
                 bam_merge_keep_single_paired_separate => VRPipe::StepOption->get(description => 'when merging bam files, separately merges single ended bam files and paired-end bam files, resulting in 2 merged bam files',
                                                                                  optional => 1,
                                                                                  default_value => 1),
                };
    }
    method inputs_definition {
        return { bam_files => VRPipe::StepIODefinition->get(type => 'bam', 
                                                            max_files => -1, 
                                                            description => '1 or more bam files',
                                                            metadata => {lane => 'lane name, or comma separated list of lane names if merged',
                                                                         library => 'library name, or comma separated list of library names if merged',
                                                                         sample => 'sample name, or comma separated list of sample names if merged',
                                                                         center_name => 'center name, or comma separated list of center names if merged',
                                                                         platform => 'sequencing platform, or comma separated list of platform names if merged',
                                                                         study => 'name of the study, or comma separated list of study names if merged',
                                                                         bases => 'total number of base pairs',
                                                                         reads => 'total number of reads (sequences)',
                                                                         paired => '0=unpaired reads were mapped; 1=paired reads were mapped',
                                                                         merged_bams => 'comma separated list of merged bam paths',
                                                                         optional => ['lane', 'library', 'sample', 'center_name', 'platform', 'study', 'merged_bams', 'bases']}
                                                            ),
                };
    }
    method body_sub {
        return sub {
            my $self = shift;
            my $options = $self->options;
            $self->handle_standard_options($options);
            my $merge_jar = $self->jar('MergeSamFiles.jar');
            
            my $opts = $options->{merge_sam_files_options};
            if ($opts =~ /MergeSamFiles/) {
                $self->throw("merge_sam_files_options should not include the MergeSamFiles task command");
            }
            
            my %merge_groups;
            my $paired = 0;
            foreach my $bam (@{$self->inputs->{bam_files}}) {
                my $meta = $bam->metadata;
                $paired ||= $meta->{paired};
                my $ended = $meta->{paired} ? 'pe' : 'se';
                push @{$merge_groups{$ended}}, $bam;
            }
            
            # Merge single and paired end bams unless option says not to
            unless ($options->{bam_merge_keep_single_paired_separate}) {
                if ($paired && exists $merge_groups{se}) {
                    push @{$merge_groups{pe}}, @{delete $merge_groups{se}};
                }
            }
            
            $self->set_cmd_summary(VRPipe::StepCmdSummary->get(exe => 'picard', 
                                   version => $self->picard_version(),
                                   summary => 'java $jvm_args -jar MergeSamFiles.jar INPUT=$bam_file(s) OUTPUT=$merged_bam '.$opts));
            
            my $req = $self->new_requirements(memory => 1000, time => 1);
            while (my ($ended, $bam_files) = each %merge_groups) {
                my @merged_bams;
                my @merged_vrfids;
                foreach my $bam (@$bam_files) {
                    my $paths = $bam->metadata->{merged_bams} || $bam->path->stringify;
                    foreach my $path (split(/,/, $paths)) {
                        push @merged_bams, $path;
                        #push @merged_vrfids, 'VF:'.VRPipe::File->get(path => $path)->id; *** this leaks memory? Uses too much memory in this single loop?
                    }
                }
                my $input_bam_paths = join(',', sort @merged_bams);
                if (length($input_bam_paths) > 10000) {
                    # this might be too large to store in the db, just use the
                    # vrpipe file ids instead
                    # $input_bam_paths = join(',', sort @merged_vrfids);
                    # *** this is only needed by bam_reheader, and without it
                    # the bam won't have any RG lines at all, but either above
                    # leak must be fixed, or bam_reheader changed to get RGs
                    # from header with this is unset. For now we just need this
                    # step to work without crashing...
                    $input_bam_paths = '';
                }
                my $merge_file = $self->output_file(output_key => 'merged_bam_files',
                                                    basename => "$ended.bam",
                                                    type => 'bam',
                                                    $input_bam_paths ? (metadata => { merged_bams => $input_bam_paths }) : ());
                
                my $temp_dir = $options->{tmp_dir} || $merge_file->dir;
                my $jvm_args = $self->jvm_args($req->memory, $temp_dir);
                
                my $in_bams = join ' INPUT=', map { $_->path } @$bam_files;
                $in_bams = ' INPUT='.$in_bams;
                my $this_cmd = $self->java_exe.qq[ $jvm_args -jar $merge_jar$in_bams OUTPUT=].$merge_file->path.qq[ $opts];
                $self->dispatch_wrapped_cmd('VRPipe::Steps::bam_merge', 'merge_and_check', [$this_cmd, $req, {output_files => [$merge_file]}]); 
            }
        };
    }
    method outputs_definition {
        return { merged_bam_files => VRPipe::StepIODefinition->get(type => 'bam', 
                                                                   max_files => -1, 
                                                                   description => '1 or more bam merged bam files',
                                                                   metadata => {lane => 'lane name, or comma separated list of lane names if merged',
                                                                                library => 'library name, or comma separated list of library names if merged',
                                                                                sample => 'sample name, or comma separated list of sample names if merged',
                                                                                center_name => 'center name, or comma separated list of center names if merged',
                                                                                platform => 'sequencing platform, or comma separated list of platform names if merged',
                                                                                study => 'name of the study, or comma separated list of study names if merged',
                                                                                bases => 'total number of base pairs',
                                                                                reads => 'total number of reads (sequences)',
                                                                                paired => '0=unpaired reads were mapped; 1=paired reads were mapped',
                                                                                merged_bams => 'comma separated list of merged bam paths',
                                                                                optional => ['lane', 'library', 'sample', 'center_name', 'platform', 'study', 'bases', 'merged_bams']}
                                                                    ),
               };
    }
    method post_process_sub {
        return sub { return 1; };
    }
    method description {
        return "Merges bam files using Picard MergeSamFiles";
    }
    method max_simultaneous {
        return 0; # meaning unlimited
    }
    method merge_and_check (ClassName|Object $self: Str $cmd_line) {
        my ($out_path) = $cmd_line =~ /OUTPUT=(\S+)/;
        my @in_paths = $cmd_line =~ /INPUT=(\S+)/g;
        @in_paths || $self->throw("cmd_line [$cmd_line] was not constructed as expected");
        $out_path || $self->throw("cmd_line [$cmd_line] was not constructed as expected");
        
        my $out_file = VRPipe::File->get(path => $out_path);
        my @in_files;
        foreach my $in_path (@in_paths) {
            push @in_files, VRPipe::File->get(path => $in_path);
        }
        
        if (scalar @in_paths == 1) {
            $in_files[0]->copy($out_file);
            return;
        }
        else {
            $out_file->disconnect;
            system($cmd_line) && $self->throw("failed to run [$cmd_line]");
        }
        
        $out_file->update_stats_from_disc(retries => 3);
        
        my $reads = 0;
        my $bases = 0;
        my $paired = 0;
        my %merge_groups;
        foreach my $in_file (@in_files) {
            my $meta = $in_file->metadata;
            $reads += $meta->{reads};
            $bases += $meta->{bases} if $meta->{bases};
            $paired ||= $meta->{paired};
            foreach my $key (keys %$meta) {
                next if (grep /^$key$/, (qw(reads bases paired merged_bams)));
                foreach my $value (split /,/, $meta->{$key}) {
                    $merge_groups{$key}->{$value} = 1;
                }
            }
        }
        my $actual_reads = $out_file->num_records;
        
        if ($actual_reads == $reads) {
            my %new_meta;
            $new_meta{reads} = $actual_reads;
            $new_meta{bases} = $bases if $bases;
            $new_meta{paired} = $paired;
            foreach my $key (keys %merge_groups) {
                my @vals = keys %{$merge_groups{$key}};
                next unless @vals == 1; # we used to store comma-separated values, but that could get too big to store in db
                $new_meta{$key} = $vals[0];
            }
            $out_file->add_metadata(\%new_meta);
            return 1;
        }
        else {
            $out_file->unlink;
            $self->throw("cmd [$cmd_line] failed because $actual_reads reads were generated in the output bam file, yet there were $reads reads in the original bam files");
        }
    }
}

1;
