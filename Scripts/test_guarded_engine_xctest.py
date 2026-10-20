#!/usr/bin/env python3
import copy
import unittest
from guarded_engine_xctest import validate_soak, validate_xctest

METHOD = 'testSeededStandardTransferToTwoDestinations'
SELECTED = 'BitMatchEngineTests.TransferSoakTests/' + METHOD
PASS = "Test Case '-[BitMatchEngineTests.TransferSoakTests " + METHOD + "]' passed (0.1 seconds).\n"


def result():
    return {'formatVersion': 2, 'outcome': 'passed', 'baseSeed': 20261020, 'requestedIterations': 1,
            'completedIterations': 1, 'verificationMode': 'standard', 'destinationsPerIteration': 2,
            'iterations': [{'iteration': 0, 'seed': 20261020, 'manifestFiles': 9, 'verifiedOutputs': 18,
                            'sourceHashesBefore': 9, 'sourceHashesAfter': 9, 'sourceDirectoriesBeforeAfter': 3,
                            'payloadPattern': 20261020 & 255}]}


class EvidenceTests(unittest.TestCase):
    def test_exact_pass_is_accepted(self):
        validate_xctest(PASS + 'Executed 1 test, with 0 failures', SELECTED)
        validate_xctest('SOAK partialbuffer' + PASS + 'Executed 1 test, with 0 failures', SELECTED)
        validate_soak(result(), 20261020, 1)

    def test_vacuous_skip_failure_and_duplicate_pass_are_rejected(self):
        for text in ['Executed 0 tests, with 0 failures', PASS + 'Executed 1 test, with 1 test skipped and 0 failures',
                     PASS + 'Executed 1 test, with 1 failures', PASS + PASS + 'Executed 1 test, with 0 failures',
                     PASS.replace('TransferSoakTests', 'OtherTests') + 'Executed 1 test, with 0 failures']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                validate_xctest(text, SELECTED)

    def test_partial_running_or_wrong_coverage_is_rejected(self):
        for key, value in [('completedIterations', 0), ('outcome', 'running'), ('baseSeed', 1), ('formatVersion', 1)]:
            receipt = result(); receipt[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_soak(receipt, 20261020, 1)
        for key, value in [('verifiedOutputs', 17), ('sourceHashesBefore', 0), ('sourceHashesAfter', 8),
                           ('sourceDirectoriesBeforeAfter', 2), ('payloadPattern', 0), ('iteration', False)]:
            receipt = copy.deepcopy(result()); receipt['iterations'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_soak(receipt, 20261020, 1)


if __name__ == '__main__':
    unittest.main()
