#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../spec_helper'

require 'puppet/application/apply'
require 'puppet/file_bucket/dipper'
require 'puppet/configurer'
require 'fileutils'

describe Puppet::Application::Apply do
  before :each do
    @apply = Puppet::Application[:apply]
    Puppet::Util::Log.stubs(:newdestination)
    Puppet::Util::Log.stubs(:level=)
  end

  [:debug,:loadclasses,:verbose,:use_nodes,:detailed_exitcodes].each do |option|
    it "should declare handle_#{option} method" do
      @apply.should respond_to("handle_#{option}".to_sym)
    end

    it "should store argument value when calling handle_#{option}" do
      @apply.options.expects(:[]=).with(option, 'arg')
      @apply.send("handle_#{option}".to_sym, 'arg')
    end
  end

  it "should set the code to the provided code when :execute is used" do
    @apply.options.expects(:[]=).with(:code, 'arg')
    @apply.send("handle_execute".to_sym, 'arg')
  end

  it "should ask Puppet::Application to parse Puppet configuration file" do
    @apply.should_parse_config?.should be_true
  end

  describe "when applying options" do

    it "should set the log destination with --logdest" do
      Puppet::Log.expects(:newdestination).with("console")

      @apply.handle_logdest("console")
    end

    it "should put the logset options to true" do
      @apply.options.expects(:[]=).with(:logset,true)

      @apply.handle_logdest("console")
    end
  end

  describe "during setup" do

    before :each do
      Puppet::Log.stubs(:newdestination)
      Puppet::Log.stubs(:level=)
      Puppet.stubs(:parse_config)
      Puppet::FileBucket::Dipper.stubs(:new)
      STDIN.stubs(:read)
      Puppet::Transaction::Report.stubs(:cache_class=)

      @apply.options.stubs(:[]).with(any_parameters)
    end

    it "should set show_diff on --noop" do
      Puppet.stubs(:[]=)
      Puppet.stubs(:[]).with(:config)
      Puppet.stubs(:[]).with(:noop).returns(true)

      Puppet.expects(:[]=).with(:show_diff, true)

      @apply.setup
    end

    it "should set console as the log destination if logdest option wasn't provided" do
      Puppet::Log.expects(:newdestination).with(:console)

      @apply.setup
    end

    it "should set INT trap" do
      Signal.expects(:trap).with(:INT)

      @apply.setup
    end

    it "should set log level to debug if --debug was passed" do
      @apply.options.stubs(:[]).with(:debug).returns(true)

      Puppet::Log.expects(:level=).with(:debug)

      @apply.setup
    end

    it "should set log level to info if --verbose was passed" do
      @apply.options.stubs(:[]).with(:verbose).returns(true)

      Puppet::Log.expects(:level=).with(:info)

      @apply.setup
    end

    it "should print puppet config if asked to in Puppet config" do
      @apply.stubs(:exit)
      Puppet.settings.stubs(:print_configs?).returns(true)

      Puppet.settings.expects(:print_configs)

      @apply.setup
    end

    it "should exit after printing puppet config if asked to in Puppet config" do
      Puppet.settings.stubs(:print_configs?).returns(true)

      lambda { @apply.setup }.should raise_error(SystemExit)
    end

    it "should tell the report handler to cache locally as yaml" do
      Puppet::Transaction::Report.expects(:cache_class=).with(:yaml)

      @apply.setup
    end
  end

  describe "when executing" do

    it "should dispatch to parseonly if parseonly is set" do
      @apply.stubs(:options).returns({})
      Puppet.stubs(:[]).with(:parseonly).returns(true)

      @apply.expects(:parseonly)
      @apply.run_command
    end

    it "should dispatch to 'apply' if it was called with 'apply'" do
      @apply.options[:catalog] = "foo"

      @apply.expects(:apply)
      @apply.run_command
    end

    it "should dispatch to main if parseonly is not set" do
      @apply.stubs(:options).returns({})
      Puppet.stubs(:[]).with(:parseonly).returns(false)

      @apply.expects(:main)
      @apply.run_command
    end

    describe "the parseonly command" do
      before :each do
        Puppet.stubs(:[]).with(:environment)
        Puppet.stubs(:[]).with(:manifest).returns("site.pp")
        Puppet.stubs(:err)
        @apply.stubs(:exit)
        @apply.options.stubs(:[]).with(:code).returns "some code"
        @collection = stub_everything
        Puppet::Resource::TypeCollection.stubs(:new).returns(@collection)
      end

      it "should use a Puppet Resource Type Collection to parse the file" do
        @collection.expects(:perform_initial_import)
        @apply.parseonly
      end

      it "should exit with exit code 0 if no error" do
        @apply.expects(:exit).with(0)
        @apply.parseonly
      end

      it "should exit with exit code 1 if error" do
        @collection.stubs(:perform_initial_import).raises(Puppet::ParseError)
        @apply.expects(:exit).with(1)
        @apply.parseonly
      end

      it "should exit with exit code 1 if error, even if --noop is set" do
        Puppet[:noop] = true
        @collection.stubs(:perform_initial_import).raises(Puppet::ParseError)
        @apply.expects(:exit).with(1)
        @apply.parseonly
      end
    end

    describe "the main command" do
      include PuppetSpec::Files

      before :each do
        Puppet[:prerun_command] = ''
        Puppet[:postrun_command] = ''

        Puppet::Node::Facts.terminus_class = :memory
        Puppet::Node.terminus_class = :memory

        @facts = Puppet::Node::Facts.new(Puppet[:node_name_value])
        @facts.save

        @node = Puppet::Node.new(Puppet[:node_name_value])
        @node.save

        @catalog = Puppet::Resource::Catalog.new
        @catalog.stubs(:to_ral).returns(@catalog)

        Puppet::Resource::Catalog.stubs(:find).returns(@catalog)

        STDIN.stubs(:read)

        @apply.stubs(:exit)

        @transaction = Puppet::Transaction.new(@catalog)
        @catalog.stubs(:apply).returns(@transaction)

        Puppet::Util::Storage.stubs(:load)
        Puppet::Configurer.any_instance.stubs(:save_last_run_summary) # to prevent it from trying to write files
      end

      it "should set the code to run from --code" do
        @apply.options[:code] = "code to run"
        Puppet.expects(:[]=).with(:code,"code to run")

        @apply.main
      end

      it "should set the code to run from STDIN if no arguments" do
        @apply.command_line.stubs(:args).returns([])
        STDIN.stubs(:read).returns("code to run")

        Puppet.expects(:[]=).with(:code,"code to run")

        @apply.main
      end

      it "should set the manifest if a file is passed on command line and the file exists" do
        manifest = tmpfile('site.pp')
        FileUtils.touch(manifest)
        @apply.command_line.stubs(:args).returns([manifest])

        Puppet.expects(:[]=).with(:manifest,manifest)

        @apply.main
      end

      it "should raise an error if a file is passed on command line and the file does not exist" do
        noexist = tmpfile('noexist.pp')
        @apply.command_line.stubs(:args).returns([noexist])
        lambda { @apply.main }.should raise_error(RuntimeError, "Could not find file #{noexist}")
      end

      it "should set the manifest to the first file and warn other files will be skipped" do
        manifest = tmpfile('starwarsIV')
        FileUtils.touch(manifest)

        @apply.command_line.stubs(:args).returns([manifest, 'starwarsI', 'starwarsII'])

        Puppet.expects(:[]=).with(:manifest,manifest)
        Puppet.expects(:warning).with('Only one file can be applied per run.  Skipping starwarsI, starwarsII')

        @apply.main
      end

      it "should set the facts name based on the node_name_fact" do
        @facts = Puppet::Node::Facts.new(Puppet[:node_name_value], 'my_name_fact' => 'other_node_name')
        @facts.save
        Puppet::Node.new('other_node_name').save
        Puppet[:node_name_fact] = 'my_name_fact'

        @apply.main

        @facts.name.should == 'other_node_name'
      end

      it "should set the node_name_value based on the node_name_fact" do
        Puppet::Node::Facts.new(Puppet[:node_name_value], 'my_name_fact' => 'other_node_name').save
        Puppet::Node.new('other_node_name').save
        Puppet[:node_name_fact] = 'my_name_fact'

        @apply.main

        Puppet[:node_name_value].should == 'other_node_name'
      end

      it "should raise an error if we can't find the facts" do
        Puppet::Node::Facts.expects(:find).returns(nil)

        lambda { @apply.main }.should raise_error
      end

      it "should raise an error if we can't find the node" do
        Puppet::Node.expects(:find).returns(nil)

        lambda { @apply.main }.should raise_error
      end

      it "should merge in our node the loaded facts" do
        @facts.values = {'key' => 'value'}

        @apply.main

        @node.parameters['key'].should == 'value'
      end

      it "should load custom classes if loadclasses" do
        @apply.options[:loadclasses] = true
        classfile = tmpfile('classfile')
        File.open(classfile, 'w') { |c| c.puts 'class' }
        Puppet[:classfile] = classfile

        @node.expects(:classes=).with(['class'])

        @apply.main
      end

      it "should compile the catalog" do
        Puppet::Resource::Catalog.expects(:find).returns(@catalog)

        @apply.main
      end

      it "should transform the catalog to ral" do

        @catalog.expects(:to_ral).returns(@catalog)

        @apply.main
      end

      it "should finalize the catalog" do
        @catalog.expects(:finalize)

        @apply.main
      end

      it "should call the prerun and postrun commands on a Configurer instance" do
        Puppet::Configurer.any_instance.expects(:execute_prerun_command)
        Puppet::Configurer.any_instance.expects(:execute_postrun_command)

        @apply.main
      end

      it "should apply the catalog" do
        @catalog.expects(:apply).returns(stub_everything('transaction'))

        @apply.main
      end

      describe "with detailed_exitcodes" do
        before :each do
          @apply.options[:detailed_exitcodes] = true
        end

        it "should exit with report's computed exit status" do
          Puppet[:noop] = false
          Puppet::Transaction::Report.any_instance.stubs(:exit_status).returns(666)
          @apply.expects(:exit).with(666)

          @apply.main
        end

        it "should exit with report's computed exit status, even if --noop is set" do
          Puppet[:noop] = true
          Puppet::Transaction::Report.any_instance.stubs(:exit_status).returns(666)
          @apply.expects(:exit).with(666)

          @apply.main
        end

        it "should always exit with 0 if option is disabled" do
          Puppet[:noop] = false
          report = stub 'report', :exit_status => 666
          @transaction.stubs(:report).returns(report)
          @apply.expects(:exit).with(0)

          @apply.main
        end

        it "should always exit with 0 if --noop" do
          Puppet[:noop] = true
          report = stub 'report', :exit_status => 666
          @transaction.stubs(:report).returns(report)
          @apply.expects(:exit).with(0)

          @apply.main
        end
      end
    end

    describe "the 'apply' command" do
      it "should read the catalog in from disk if a file name is provided" do
        @apply.options[:catalog] = "/my/catalog.pson"
        File.expects(:read).with("/my/catalog.pson").returns "something"
        Puppet::Resource::Catalog.stubs(:convert_from).with(:pson,'something').returns Puppet::Resource::Catalog.new
        @apply.apply
      end

      it "should read the catalog in from stdin if '-' is provided" do
        @apply.options[:catalog] = "-"
        $stdin.expects(:read).returns "something"
        Puppet::Resource::Catalog.stubs(:convert_from).with(:pson,'something').returns Puppet::Resource::Catalog.new
        @apply.apply
      end

      it "should deserialize the catalog from the default format" do
        @apply.options[:catalog] = "/my/catalog.pson"
        File.stubs(:read).with("/my/catalog.pson").returns "something"
        Puppet::Resource::Catalog.stubs(:default_format).returns :rot13_piglatin
        Puppet::Resource::Catalog.stubs(:convert_from).with(:rot13_piglatin,'something').returns Puppet::Resource::Catalog.new
        @apply.apply
      end

      it "should fail helpfully if deserializing fails" do
        @apply.options[:catalog] = "/my/catalog.pson"
        File.stubs(:read).with("/my/catalog.pson").returns "something syntacically invalid"
        lambda { @apply.apply }.should raise_error(Puppet::Error)
      end

      it "should convert plain data structures into a catalog if deserialization does not do so" do
        @apply.options[:catalog] = "/my/catalog.pson"
        File.stubs(:read).with("/my/catalog.pson").returns "something"
        Puppet::Resource::Catalog.stubs(:convert_from).with(:pson,"something").returns({:foo => "bar"})
        Puppet::Resource::Catalog.expects(:pson_create).with({:foo => "bar"}).returns(Puppet::Resource::Catalog.new)
        @apply.apply
      end

      it "should convert the catalog to a RAL catalog and use a Configurer instance to apply it" do
        @apply.options[:catalog] = "/my/catalog.pson"
        File.stubs(:read).with("/my/catalog.pson").returns "something"
        catalog = Puppet::Resource::Catalog.new
        Puppet::Resource::Catalog.stubs(:convert_from).with(:pson,'something').returns catalog
        catalog.expects(:to_ral).returns "mycatalog"

        configurer = stub 'configurer'
        Puppet::Configurer.expects(:new).returns configurer
        configurer.expects(:run).with(:catalog => "mycatalog")

        @apply.apply
      end
    end
  end
end