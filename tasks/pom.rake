require 'builder'
require './tasks/util'

# Buildr does provide some fairly sophisticated POM generation in the buildr/custom_pom
# module.  However, it does not really allow for definition and configuration of Maven
# plugins.  At some point it may be worth taking some code from it as its method of
# resolving all the dependencies is more comprehensive than ours.  It handles adding
# test, and optional dependencies, for example.
module PomTask
  include ::Candlepin::Util

  class Config
    def initialize(project)
      @project = project
    end

    def enabled?
      !@project.packages.empty?
    end

    attr_writer :pom_parent
    def pom_parent
      @pom_parent ||= PomTask.top_project(@project)
    end

    def provided_dependencies=(val)
      if val.respond_to?(:each)
        @provided_dependencies = val
      else
        @provided_dependencies = [val]
      end
    end

    def provided_dependencies
      @provided_dependencies ||= []
    end

    def runtime_dependencies=(val)
      if val.respond_to?(:each)
        @runtime_dependencies = val
      else
        @runtime_dependencies = [val]
      end
    end

    def runtime_dependencies
      @runtime_dependencies ||= []
    end

    def optional_dependencies=(val)
      if val.respond_to?(:each)
        @optional_dependencies = val
      else
        @optional_dependencies = [val]
      end
    end

    def optional_dependencies
      @optional_dependencies ||= []
    end

    attr_writer :pom_parent_suffix
    def pom_parent_suffix
      @pom_parent_suffix ||= "-parent"
    end

    attr_writer :create_assembly
    def create_assembly
      @create_assembly ||= true
    end

    attr_writer :additional_properties
    def additional_properties
      @additional_properties ||= {}
    end

    attr_writer :name
    def name
      @name ||= @project.name
    end

    attr_writer :description
    def description
      @description ||= name
    end

    # A list of procs that will be executed in the plugin configuration
    # section of the POM.  The proc receives the XML Builder object and
    # the Buildr Project object. Note that the XML Builder object
    # will already be within a plugin element.  Example:
    #
    # p = Proc.new do |xml, project|
    #   xml.groupId("org.apache.maven.plugins")
    #   xml.artifactId("maven-gpg-plugin")
    #   xml.executions do
    #     xml.execution do
    #       xml.id("sign-artifacts")
    #       [...]
    #     end
    #   end
    # end
    #
    # plugin_procs << p
    #
    # It is unlikely that you want to call plugin_procs= as that would
    # clear the default procs that are created to add some essential maven
    # plugins.  Therefore that method is not provided.  If a plugin_procs=
    # method becomes necessary, here is an implementation:
    #
    # def plugin_procs=(val)
    #   if val.respond_to?(:each)
    #     @plugin_procs = val
    #   else
    #     @plugin_procs = [val]
    #   end
    # end
    def plugin_procs
      unless @plugin_procs
        @plugin_procs = []
        default_plugins = [
          "maven-surefire-plugin",
          "maven-assembly-plugin",
          "maven-compiler-plugin",
        ]
        default_plugins.each do |p|
          @plugin_procs << Proc.new do |xml, proj|
            xml.groupId("org.apache.maven.plugins")
            xml.artifactId(p)
          end
        end
      end
      @plugin_procs
    end

    def dependency_procs
      @dependency_procs ||= []
    end

    # The below are primarily for compatibility for Buildr's built-in POM plugin which the IDEA plugin uses
    attr_accessor :url
    attr_accessor :scm_url
    attr_accessor :scm_connection
    attr_accessor :scm_developer_connection
    attr_accessor :issues_url
    attr_accessor :issues_system

    attr_writer :licenses
    def licenses
      @licenses ||= {}
    end

    # Completely for compatibility.  The Maven developer section is a pain to build.  Every developer needs
    # an id, name, email, and list of roles.  Forget it.  I'll go into movies if I want to get famous.
    attr_writer :developers
    def developers
      @developers ||= []
    end

  end

  class PomBuilder
    attr_reader :artifact
    attr_reader :dependencies
    attr_reader :project
    attr_reader :config

    def initialize(artifact, project)
      @artifact = artifact
      @project = project
      @config = project.pom
      # Filter anything that can't be treated as an artifact
      @dependencies = project.compile.dependencies.select do |dep|
        dep.respond_to?(:to_spec)
      end
      @buffer = ""
    end

    def dependencies=(val)
      @dependencies = val.select do |dep|
        dep.respond_to?(:to_spec)
      end
    end

    def build
      artifact_spec = artifact.to_hash
      parent_spec = PomTask.as_pom_artifact(@config.pom_parent).to_hash

      # Ugly hack to allow for the fact that the "server" project artifactId is
      # "candlepin" which conflicts with the name of the top-level buildr project
      parent_spec[:id] = "#{parent_spec[:id]}#{@config.pom_parent_suffix}"

      xml = Builder::XmlMarkup.new(:target => @buffer, :indent => 2)
      xml.instruct!
      xml.comment!(" vim: set expandtab sts=2 sw=2 ai: ")
      xml.comment!("**This file is auto-generated by Buildr.  Changes may be lost.**")
      xml.project(
        "xsi:schemaLocation" => "http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd",
        "xmlns" => "http://maven.apache.org/POM/4.0.0",
        "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance"
      ) do
        xml.modelVersion("4.0.0")

        xml.parent do
          xml.groupId(parent_spec[:group])
          xml.artifactId(parent_spec[:id])
          xml.version(parent_spec[:version])
          project_path = Pathname.new(@project.base_dir)
          parent_path = Pathname.new(@config.pom_parent.base_dir)
          xml.relativePath(parent_path.relative_path_from(project_path).to_s)
        end

        xml.groupId(artifact_spec[:group])
        xml.artifactId(artifact_spec[:id])
        xml.version(artifact_spec[:version])
        xml.packaging(artifact_spec[:type].to_s)

        xml.name @config.name if @config.name
        xml.description @config.description if @config.description
        xml.url @config.url if @config.url

        xml.licenses do
          @config.licenses.each_pair do |name, url|
            xml.license do
              xml.name name
              xml.url url
              xml.distribution 'repo'
            end
          end
        end unless @config.licenses.empty?

        if @config.scm_url || @config.scm_connection || @config.scm_developer_connection
          xml.scm do
            xml.connection @config.scm_connection if @config.scm_connection
            xml.developerConnection @config.scm_developer_connection if @config.scm_developer_connection
            xml.url @config.scm_url if @config.scm_url
          end
        end

        if @config.issues_url
          xml.issueManagement do
            xml.url @config.issues_url
            xml.system @config.issues_system if @config.issues_system
          end
        end

        version_properties = {}

        # Manage version numbers in a properties section
        xml.properties do
          @config.additional_properties.each do |k, v|
            xml.tag!(k, v)
          end
          dependencies.each do |dep|
            h = dep.to_hash
            prop_name = "#{h[:group]}-#{h[:id]}.version"
            xml.tag!(prop_name, h[:version])
            version_properties[h] = "${#{prop_name}}"
          end
        end

        xml.dependencies do
          dependencies.each do |dep|
            h = dep.to_hash
            xml.dependency do
              xml.groupId(h[:group])
              xml.artifactId(h[:id])
              xml.version(version_properties[h])

              if @config.provided_dependencies.include?(dep.to_spec)
                xml.scope("provided")
              elsif @config.runtime_dependencies.include?(dep.to_spec)
                xml.scope("runtime")
              end

              if @config.optional_dependencies.include?(dep.to_spec)
                xml.optional("true")
              end

              # We manage all dependencies explicitly and we don't want to drag
              # in any conflicting versions.  For example, we use Guice 3.0 but the
              # Resteasy Guice library has a dependency on Guice 2.0.
              xml.exclusions do
                xml.exclusion do
                  xml.groupId('*')
                  xml.artifactId('*')
                end
              end
            end
          end

          config.dependency_procs.each do |dependency_proc|
            xml.dependency do
              dependency_proc.call(xml, project)
            end
          end
        end

        xml.build do
          xml.plugins do
            config.plugin_procs.each do |plugin_proc|
              xml.plugin do
                plugin_proc.call(xml, project)
              end
            end
          end
        end
      end
    end

    def content
      @buffer
    end

    def write_to_file(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      File.open(destination, "w") { |f| f.write(@buffer) }
    end
  end

  module ProjectExtension
    include Extension

    def pom
      @pom ||= PomTask::Config.new(project)
    end

    first_time do
      desc 'Generate a POM file'
      Project.local_task('pom')
    end

    before_define do |project|
      project.recursive_task('pom')
    end

    after_define do |project|
      pom = project.pom
      if pom.enabled?
        project.packages.each do |pkg|
          if %w[jar war ear].include?(pkg.type.to_s)
            # Inject code into the package task.  E.g. WarTask or JarTask
            class << pkg
              def pom_xml
                self.pom.content
              end

              def pom
                unless @pom
                  if @project.packages.length > 1 && self.type != :war
                    destination = Util.replace_extension(name, 'pom')
                  else
                    destination = @project.path_to("pom.xml")
                  end

                  spec = {
                    :group => group,
                    :id => id,
                    :version => version,
                    :type => :pom
                  }

                  # The four lines below are copied from Buildr.artifact
                  @pom = Artifact.define_task(destination)
                  @pom.send(:apply_spec, spec)
                  Rake::Task['rake:artifacts'].enhance([@pom])
                  Artifact.register(@pom)

                  @pom.enhance do |task|
                    info("Wrote #{task}")
                  end

                  xml = PomBuilder.new(self, @project)

                  # We do some manipulation of the generated WARs to add
                  # optional dependencies (e.g. HSQLDB for Candlepin) in the
                  # packaging task so we need to reflect that in the Maven-built
                  # WAR.
                  if self.type == :war
                    xml.dependencies += self.libs
                    xml.dependencies.uniq!
                  end
                  xml.build

                  @pom.content(xml.content)
                end
                @pom
              end

              private

              def associate_with(project)
                @project = project
              end
            end
            pkg.instance_variable_set('@pom', nil)
            pkg.send(:associate_with, project)

            project.task('pom').enhance([pkg.pom])
          end
        end
      end
    end
  end
end

class Buildr::Project
  include PomTask::ProjectExtension
end
