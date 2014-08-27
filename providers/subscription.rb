#
# Author:: Baptiste Courtois (<b.courtois@criteo.com>)
# Cookbook Name:: wsus-server
# Provider:: subscription
#
# Copyright:: Copyright (c) 2014 Criteo.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use_inline_resources

include WsusServer::BaseProvider

def load_current_resource
  require 'YAML'

  @current_resource = Chef::Resource::WsusServerSubscription.new(@new_resource.name, @run_context)
  # Load current_resource from Powershell
  script = <<-EOS
    $assembly = [Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
    if ($assembly -ne $null) {
      # Sets invariant culture for current session to avoid Floating point conversion issue
      [Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

      # Defines single-level "YAML" formatters to avoid DateTime and TimeSpan conversion issue in ruby
      $valueFormatter = { param($_); if ($_ -is [DateTime] -or $_ -is [TimeSpan]) { "'$($_)'" } else { $_ } }
      $objectFormatter = { param($_); $_.psobject.Properties | foreach { "$($_.name): $(&$valueFormatter $_.value)" } }

      $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer(#{endpoint_params})
      $subscription = $wsus.GetSubscription()

      # First document is the Subscription configuration
      &$objectFormatter $subscription

      # Second document is the list of enabled categories
      Write-Host '---'
      $subscription.GetUpdateCategories() | foreach { "- " + $_.Title }

      # Third document is the list of enabled classifications
      Write-Host '---'
      $subscription.GetUpdateClassifications() | foreach { "- " + $_.Title }
    }
  EOS
  properties, categories, classifications = YAML.load_stream(powershell_out64(script).stdout)

  @current_resource.properties properties
  @current_resource.categories categories
  @current_resource.classifications classifications
end

action :configure do
  updated_properties = diff_hash(@new_resource.properties, @current_resource.properties)
  categories_unchanged = array_equals(@new_resource.categories, @current_resource.categories)
  classifications_unchanged = array_equals(@new_resource.classifications, @current_resource.classifications)

  unless updated_properties.empty? && categories_unchanged && classifications_unchanged
    script = <<-EOS
      [Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration') | Out-Null
      # Sets invariant culture for current session to avoid Floating point conversion issue
      [Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

      $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer(#{endpoint_params})
      $conf = $wsus.GetSubscription()
    EOS

    if @new_resource.synchronize_categories
      script << <<-EOS
      $conf.StartSynchronizationForCategoryOnly()

      $timeout = [DateTime]::Now.AddMinutes(10)
      do {
        Start-Sleep -Seconds 5
        $status = $conf.GetSynchronizationProgress().Phase
      } until ($status -eq 'NotProcessing' -or $timeout -lt [DateTime]::Now)

      # Renew update server and subscription
      $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer(#{endpoint_params})
      $conf = $wsus.GetSubscription()
      EOS
    end

    unless categories_unchanged
      categories = powershell_value(@new_resource.categories)
      script << <<-EOS
      $categories = $wsus.GetUpdateCategories() | where Title -in #{categories}
      if ($categories -ne $null)
      {
        $collection = New-Object Microsoft.UpdateServices.Administration.UpdateCategoryCollection
        $collection.AddRange($categories)
        $conf.SetUpdateCategories($collection)
      }
      EOS
    end

    unless classifications_unchanged
      classifications = powershell_value(@new_resource.classifications)
      script << <<-EOS
      $classifications = $wsus.GetUpdateClassifications() | where Title -in #{classifications}
      if ($classifications -ne $null)
      {
        $collection = New-Object Microsoft.UpdateServices.Administration.UpdateClassificationCollection
        $collection.AddRange($classifications)
        $conf.SetUpdateClassifications($collection)
      }
      EOS
    end

    updated_properties.each do |k, v|
      script << "      $conf.#{k} = #{powershell_value(v)}\n"
    end
    script << '      $conf.Save()'

    powershell_script 'Subscription configuration' do
      code script
    end
  end
end
