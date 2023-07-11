{ lib
, buildPythonPackage
, fetchFromGitHub
, writeText
, fetchpatch
, isPy27
, pytestCheckHook
, pytest-mpl
, numpy
, scipy
, scikit-learn
, pandas
, transformers
, opencv4
, lightgbm
, catboost
, pyspark
, sentencepiece
, tqdm
, slicer
, numba
, matplotlib
, nose
, lime
, cloudpickle
, ipython
}:

buildPythonPackage rec {
  pname = "shap";
  version = "0.42.0";
  disabled = isPy27;

  src = fetchFromGitHub {
    owner = "slundberg";
    repo = pname;
    rev = "refs/tags/v${version}";
    hash = "sha256-VGlswr9ywHk4oKSmmAzEC7+E0V2XEFlg19zXVktUdhc=";
  };

  patches = [
    (fetchpatch {
      name = "fix-circular-import-error.patch";
      url = "https://github.com/slundberg/shap/commit/ce118526b19b4a206cf8b496c2cd2b215ef7a91b.patch";
      hash = "sha256-n2yFjFgc2VSFKb4ZJx775HblULWfnQSEnqjfPa8AOt0=";
    })
  ];

  propagatedBuildInputs = [
    numpy
    scipy
    scikit-learn
    pandas
    tqdm
    slicer
    numba
    cloudpickle
  ];

  passthru.optional-dependencies = {
    plots = [ matplotlib ipython ];
    others = [ lime ];
  };

  preCheck = let
    # This pytest hook mocks and catches attempts at accessing the network
    # tests that try to access the network will raise, get caught, be marked as skipped and tagged as xfailed.
    conftestSkipNetworkErrors = writeText "conftest.py" ''
      from _pytest.runner import pytest_runtest_makereport as orig_pytest_runtest_makereport
      import urllib, requests, transformers

      class NetworkAccessDeniedError(RuntimeError): pass
      def deny_network_access(*a, **kw):
        raise NetworkAccessDeniedError

      requests.head = deny_network_access
      requests.get  = deny_network_access
      urllib.request.urlopen = deny_network_access
      urllib.request.Request = deny_network_access
      transformers.AutoTokenizer.from_pretrained = deny_network_access

      def pytest_runtest_makereport(item, call):
        tr = orig_pytest_runtest_makereport(item, call)
        if call.excinfo is not None and call.excinfo.type is NetworkAccessDeniedError:
            tr.outcome = 'skipped'
            tr.wasxfail = "reason: Requires network access."
        return tr
    '';
  in ''
    export HOME=$TMPDIR
    # when importing the local copy the extension is not found
    rm -r shap

    # Add pytest hook skipping tests that access network.
    # These tests are marked as "Expected fail" (xfail)
    cat ${conftestSkipNetworkErrors} >> tests/conftest.py
  '';

  nativeCheckInputs = [
    pytestCheckHook
    pytest-mpl
    matplotlib
    nose
    ipython
    # optional dependencies, which only serve to enable more tests:
    opencv4
    #pytorch # we already skip all its tests due to slowness, adding it does nothing
    transformers
    #xgboost # numerically unstable? xgboost tests randomly fails pending on nixpkgs revision
    lightgbm
    catboost
    pyspark
    sentencepiece
  ];
  disabledTestPaths = [
    # The resulting plots look sane, but does not match pixel-perfectly with the baseline.
    # Likely due to a matplotlib version mismatch, different backend, or due to missing fonts.
    "tests/plots/test_summary.py" # FIXME: enable
  ];
  disabledTests = [
    # The same reason as above test_summary.py
    "test_simple_bar_with_cohorts_dict"
    "test_random_summary_violin_with_data2"
    "test_random_summary_layered_violin_with_data2"
  ];

  pythonImportsCheck = [
    "shap"
    "shap.explainers"
    "shap.explainers.other"
    "shap.plots"
    "shap.plots.colors"
    "shap.benchmark"
    "shap.maskers"
    "shap.utils"
    "shap.actions"
    "shap.models"
  ];

  meta = with lib; {
    description = "A unified approach to explain the output of any machine learning model";
    homepage = "https://github.com/slundberg/shap";
    changelog = "https://github.com/slundberg/shap/releases/tag/v${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ evax ];
    platforms = platforms.unix;
  };
}
